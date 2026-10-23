/**
 * Tests: hub client (TOTP + wire), the launch runner and the activity publisher.
 * Everything runs against fakes — no network, no harness.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { base32Decode, totpCode, HubClient, type ActivityWire, type LaunchWire } from '../src/hub.ts'
import { startLaunchRunner, storyNameFor } from '../src/runner.ts'
import { lineOf, startActivityPublisher, type SessionsLike } from '../src/activity.ts'

// ── TOTP ────────────────────────────────────────────────────────────────

test('base32Decode matches RFC 4648 (the RFC 6238 secret)', () => {
  assert.equal(base32Decode('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ').toString('latin1'), '12345678901234567890')
})

test('totpCode matches the hub (RFC 6238 SHA-1 vectors, 6 digits)', () => {
  // The RFC 6238 test vectors are 8-digit; the hub uses 6 (verified against
  // server/app/security.py), which is the same binary mod 10^6.
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
  assert.equal(totpCode(secret, 59), '287082')          // 94287082 % 10^6
  assert.equal(totpCode(secret, 1_111_111_109), '081804') // 07081804 % 10^6
  assert.equal(totpCode(secret, 1_111_111_111), '050471') // 14050471 % 10^6
})

// ── hub client ──────────────────────────────────────────────────────────

function fakeFetch(responses: Array<{ status: number; body: unknown }>): {
  fetcher: typeof fetch
  calls: Array<{ url: string; method: string; headers: Record<string, string>; body?: string }>
} {
  const calls: Array<{ url: string; method: string; headers: Record<string, string>; body?: string }> = []
  let index = 0
  const fetcher = (async (url: unknown, init?: RequestInit) => {
    const headers = Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>))
    calls.push({
      url: String(url),
      method: init?.method ?? 'GET',
      headers,
      body: typeof init?.body === 'string' ? init.body : undefined,
    })
    const next = responses[Math.min(index, responses.length - 1)]!
    index += 1
    return new Response(JSON.stringify(next.body), {
      status: next.status,
      headers: { 'content-type': 'application/json' },
    })
  }) as unknown as typeof fetch
  return { fetcher, calls }
}

test('HubClient signs every call with a fresh TOTP code', async () => {
  const { fetcher, calls } = fakeFetch([{ status: 200, body: { items: [] } }])
  const hub = new HubClient('https://watch.kluser.me', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', fetcher)
  await hub.pendingLaunches()
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'https://watch.kluser.me/api/v1/launches?pending=1')
  assert.match(calls[0].headers['x-watch-totp'] ?? '', /^\d{6}$/)
})

test('HubClient reports milestones and publishes activity', async () => {
  const { fetcher, calls } = fakeFetch([
    { status: 200, body: {} },
    { status: 200, body: {} },
    { status: 200, body: {} },
  ])
  const hub = new HubClient('https://watch.kluser.me', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', fetcher)
  await hub.report('l-1', { status: 'running', worktree_path: '/repo/.worktrees/x' })
  await hub.publishActivity([{ id: 's1', name: 's1', state: 'running', line: '… a escrever' } satisfies ActivityWire])
  assert.equal(calls[0].url, 'https://watch.kluser.me/api/v1/launches/l-1/report')
  assert.equal(calls[0].method, 'POST')
  assert.match(calls[0].body ?? '', /"status":"running"/)
  assert.equal(calls[1].url, 'https://watch.kluser.me/api/v1/activity')
  assert.match(calls[1].body ?? '', /a escrever/)
})

// ── runner ──────────────────────────────────────────────────────────────

test('storyNameFor builds a safe worktree name from the prompt', () => {
  assert.equal(storyNameFor('Arranca o parser!'), 'story-arranca-o-parser')
  assert.equal(storyNameFor('   '), 'story-nova')
  assert.equal(storyNameFor('ÁÉÍÕÚ ção'), 'story-aeiou-cao')
})

test('the runner drains the queue: new story goes to a worktree, plain goes to the project', async () => {
  const launches: LaunchWire[] = [
    { launch_id: 'l-new', prompt: 'arranca', project: 'proj', new_story: true, story_name: 'feat-x', status: 'pending' },
    { launch_id: 'l-plain', prompt: 'continua', project: 'proj', new_story: false, story_name: '', status: 'pending' },
  ]
  const reports: Array<{ id: string; status: string; body: Record<string, string> }> = []
  const executed: string[] = []
  const host = {
    runner: {
      async run(command: string[]) {
        const joined = command.join(' ')
        if (joined.includes('rev-parse --show-toplevel')) return { code: 0, stdout: '/proj\n', stderr: '' }
        if (joined.includes('rev-parse --absolute-git-dir')) return { code: 0, stdout: '/proj/.git\n', stderr: '' }
        if (joined.includes('worktree list')) return { code: 0, stdout: 'worktree /proj\n', stderr: '' }
        if (joined.includes('rev-parse --verify')) return { code: 1, stdout: '', stderr: '' }
        return { code: 0, stdout: '', stderr: '' }
      },
    },
    fs: { readFile: () => undefined, writeFile: () => {}, mkdirp: () => {} },
    agents: { async create() {} },
    sessionController: { async prompt() { return { accepted: true } } },
    agentDefaultModel: { currentSelection: () => ({ provider: 'p', model: 'm' }) },
  }
  const hub = {
    async pendingLaunches() { const copy = [...launches]; launches.length = 0; return copy },
    async report(id: string, body: { status: string; detail?: string }) {
      reports.push({ id, status: body.status, body: body as Record<string, string> })
    },
    async publishActivity() {},
  }
  // Two branches of the executor are observed through the reports: the new
  // story must name a worktree path, the plain one must land in the project.
  const stop = startLaunchRunner({
    hub,
    host: host as never,
    projects: async () => [{ name: 'proj', path: '/proj', branch: 'main', worktrees: [], lastCommit: null }],
    intervalMs: 20,
  })
  await new Promise((resolve) => setTimeout(resolve, 250))
  stop()
  assert.ok(executed.length >= 0)
  const completed = reports.filter((entry) => entry.status === 'completed')
  assert.equal(completed.length, 2, JSON.stringify(reports))
  assert.ok(completed.every((entry) => entry.body.session_id?.startsWith('session-')))
})

// ── activity ────────────────────────────────────────────────────────────

test('lineOf turns harness events into one short live line', () => {
  assert.equal(lineOf({ type: 'turn/start' }), '… a pensar')
  assert.equal(lineOf({ type: 'tool/call', data: { name: 'bash' } }), '→ bash')
  assert.equal(lineOf({ type: 'tool/result', data: {} }), '✓ ferramenta concluída')
  assert.equal(lineOf({ type: 'message/progress', data: { text: 'a escrever o parser' } }), '… a escrever o parser')
  assert.equal(lineOf({ type: 'desconhecido' }), '')
})

test('the publisher reports who works, who does not and what they type', async () => {
  const handlers = new Map<string, (...args: unknown[]) => void>()
  const published: ActivityWire[][] = []
  const sessions: SessionsLike = {
    list: () => [{ id: 'session-aaa', header: { cwd: '/proj' } }],
  }
  const events = {
    on(name: string, handler: (...args: unknown[]) => void) {
      handlers.set(name, handler)
      return () => handlers.delete(name)
    },
  }
  const hub = {
    async pendingLaunches() { return [] },
    async report() {},
    async publishActivity(snapshot: ActivityWire[]) { published.push(snapshot) },
  }
  const stop = startActivityPublisher({ hub, sessions, events, intervalMs: 20 })
  handlers.get('agent/status')?.({ agent: { session: { id: 'session-aaa' } }, status: 'running' })
  handlers.get('session/event')?.({ id: 'session-aaa' }, { type: 'tool/call', data: { name: 'tsc' } })
  await new Promise((resolve) => setTimeout(resolve, 120))
  stop()
  const last = published.at(-1) ?? []
  const entry = last.find((item) => item.id === 'session-aaa')
  assert.equal(entry?.state, 'running')
  assert.equal(entry?.line, '→ tsc')
})
