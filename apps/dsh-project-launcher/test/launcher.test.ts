/**
 * Tests: project inventory, worktree planning, and the launch orchestration.
 * Everything runs against fakes — no git, no harness, no disk.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { expandPath, findProject, scanProjects, type FsLike, type GitFactsRunner } from '../src/projects.ts'
import { planWorktree, validateWorktreeName, withExcludeEntry } from '../src/worktree.ts'
import { launchPrompt, type LaunchHost } from '../src/launch.ts'
import { LauncherError } from '../src/shared.ts'
import { assertValidConfig } from '../src/index.ts'

// ── fakes ────────────────────────────────────────────────────────────────

function fakeFs(directories: string[], gitDirs: string[] = directories): FsLike {
  const dirSet = new Set(directories)
  const gitSet = new Set(gitDirs)
  return {
    existsSync(path) {
      if (dirSet.has(path)) return true
      // The `.git` marker of a project: a file (linked) or a directory (main).
      return path.endsWith('/.git') && gitSet.has(path.slice(0, -'/.git'.length))
    },
    isDirectory(path) { return dirSet.has(path) },
    readdir(path) {
      return [...dirSet].filter((d) => d.startsWith(`${path}/`) && !d.slice(path.length + 1).includes('/'))
        .map((d) => d.slice(path.length + 1))
    },
    homedir() { return '/home/test' },
  }
}

const facts: GitFactsRunner = {
  async branch() { return 'main' },
  async lastCommit() { return '2026-10-22T10:00:00-03:00' },
  async worktrees(dir) { return [dir, `${dir}/.worktrees/feature`] },
}

// ── inventory ────────────────────────────────────────────────────────────

test('scanProjects lists git projects under each root, sorted by name', async () => {
  const fs = fakeFs(
    ['/Projects', '/Projects/alpha', '/Projects/beta', '/Projects/not-a-repo'],
    ['/Projects/alpha', '/Projects/beta'],
  )
  const projects = await scanProjects(['/Projects'], fs, facts)
  assert.deepEqual(projects.map((p) => p.name), ['alpha', 'beta'])
  assert.equal(projects[0].branch, 'main')
  assert.deepEqual(projects[0].worktrees, ['/Projects/alpha/.worktrees/feature'])
  assert.equal(projects[0].lastCommit, '2026-10-22T10:00:00-03:00')
})

test('scanProjects expands ~ and skips missing roots', async () => {
  const fs = fakeFs(['/home/test/Projects', '/home/test/Projects/one'], ['/home/test/Projects/one'])
  const projects = await scanProjects(['~/Projects', '/nope'], fs, facts)
  assert.deepEqual(projects.map((p) => p.name), ['one'])
  assert.equal(expandPath('~', '/home/test'), '/home/test')
  assert.equal(expandPath('~/x', '/home/test'), '/home/test/x')
  assert.equal(expandPath('/abs', '/home/test'), '/abs')
})

test('findProject matches by name or absolute path', async () => {
  const fs = fakeFs(['/Projects', '/Projects/alpha'], ['/Projects/alpha'])
  const projects = await scanProjects(['/Projects'], fs, facts)
  assert.equal(findProject(projects, 'alpha')?.path, '/Projects/alpha')
  assert.equal(findProject(projects, '/Projects/alpha')?.name, 'alpha')
  assert.equal(findProject(projects, 'missing'), undefined)
})

// ── worktree planning ────────────────────────────────────────────────────

test('validateWorktreeName accepts the safe grammar and refuses the rest', () => {
  assert.equal(validateWorktreeName(' feat-1.2_x '), 'feat-1.2_x')
  assert.throws(() => validateWorktreeName('../escape'), LauncherError)
  assert.throws(() => validateWorktreeName('has space'), LauncherError)
  assert.throws(() => validateWorktreeName(''), LauncherError)
  assert.throws(() => validateWorktreeName('..'), LauncherError)
})

test('planWorktree targets <repo>/.worktrees/<name> and excludes it from status', () => {
  const plan = planWorktree('/repo', '/repo/.git', 'feature')
  assert.equal(plan.worktreePath, '/repo/.worktrees/feature')
  assert.equal(plan.branch, 'feature')
  assert.equal(plan.excludeEntry, '.worktrees/')
  assert.equal(plan.excludeFile, '/repo/.git/info/exclude')
})

test('planWorktree excludes nothing when the root sits outside the repository', () => {
  const plan = planWorktree('/repo', '/repo/.git', 'feature', '/elsewhere')
  assert.equal(plan.worktreePath, '/elsewhere/feature')
  assert.equal(plan.excludeEntry, null)
})

test('withExcludeEntry is idempotent and preserves shape', () => {
  const once = withExcludeEntry(undefined, '.worktrees/')
  assert.equal(once, '# added by dsh-project-launcher (created worktrees live here)\n.worktrees/\n')
  assert.equal(withExcludeEntry(once, '.worktrees/'), once)
  const appended = withExcludeEntry('*.log\n', '.worktrees/')
  assert.match(appended, /\*\.log\n# added by dsh-project-launcher/)
})

// ── launch orchestration ─────────────────────────────────────────────────

function fakeHost(overrides: Partial<Record<'branch' | 'worktree', boolean>> = {}): {
  host: LaunchHost
  calls: { created: unknown[]; prompts: unknown[]; runs: string[][] }
  files: Map<string, string>
} {
  const calls = { created: [] as unknown[], prompts: [] as unknown[], runs: [] as string[][] }
  const files = new Map<string, string>()
  const host: LaunchHost = {
    runner: {
      async run(command) {
        calls.runs.push(command)
        const joined = command.join(' ')
        if (joined.includes('rev-parse --show-toplevel')) return { code: 0, stdout: '/repo\n', stderr: '' }
        if (joined.includes('rev-parse --absolute-git-dir')) return { code: 0, stdout: '/repo/.git\n', stderr: '' }
        if (joined.includes('rev-parse --verify')) {
          return overrides.branch === true ? { code: 0, stdout: 'ref\n', stderr: '' } : { code: 1, stdout: '', stderr: '' }
        }
        if (joined.includes('worktree list')) {
          return {
            code: 0,
            stdout: overrides.worktree === true
              ? 'worktree /repo\nworktree /repo/.worktrees/feature\n'
              : 'worktree /repo\n',
            stderr: '',
          }
        }
        return { code: 0, stdout: '', stderr: '' }
      },
    },
    fs: {
      readFile(path) { return files.get(path) },
      writeFile(path, content) { files.set(path, content) },
      mkdirp() { /* no disk in tests */ },
    },
    agents: {
      async create(options) { calls.created.push(options) },
    },
    sessionController: {
      async prompt(request) { calls.prompts.push(request); return { accepted: true } },
    },
    agentDefaultModel: {
      currentSelection() { return { provider: 'deepseek-official', model: 'deepseek-v4-flash' } },
    },
  }
  return { host, calls, files }
}

test('launchPrompt creates the worktree, the session inside it and fires the prompt', async () => {
  const { host, calls, files } = fakeHost()
  const result = await launchPrompt(host, {
    projectDir: '/repo',
    name: 'my-feature',
    prompt: '  implement the thing  ',
  })
  assert.equal(result.branch, 'my-feature')
  assert.equal(result.worktreePath, '/repo/.worktrees/my-feature')
  assert.equal(result.promptAccepted, true)
  assert.match(calls.runs[4].join(' '), /worktree add/)
  assert.equal(calls.created.length, 1)
  const created = calls.created[0] as { meta?: { cwd?: string }; sessionId: string }
  assert.equal(created.meta?.cwd, '/repo/.worktrees/my-feature')
  assert.match(created.sessionId, /^session-/)
  assert.equal(calls.prompts.length, 1)
  const prompt = calls.prompts[0] as { content: { text: string }[]; mode: string; sessionId: string }
  assert.equal(prompt.mode, 'queue')
  assert.equal(prompt.content[0].text, 'implement the thing')
  assert.equal(prompt.sessionId, created.sessionId)
  assert.match(files.get('/repo/.git/info/exclude') ?? '', /\.worktrees\//)
})

test('launchPrompt refuses an existing worktree or branch before touching git', async () => {
  const existing = fakeHost({ worktree: true })
  await assert.rejects(
    launchPrompt(existing.host, { projectDir: '/repo', name: 'feature', prompt: 'x' }),
    (error: unknown) => error instanceof LauncherError && error.code === 'worktree-exists',
  )
  assert.equal(existing.calls.created.length, 0)

  const taken = fakeHost({ branch: true })
  await assert.rejects(
    launchPrompt(taken.host, { projectDir: '/repo', name: 'feature', prompt: 'x' }),
    (error: unknown) => error instanceof LauncherError && error.code === 'branch-exists',
  )
  assert.equal(taken.calls.created.length, 0)
})

test('launchPrompt refuses an invalid name or an empty prompt', async () => {
  const { host } = fakeHost()
  await assert.rejects(
    launchPrompt(host, { projectDir: '/repo', name: '../nope', prompt: 'x' }),
    (error: unknown) => error instanceof LauncherError && error.code === 'invalid-name',
  )
  await assert.rejects(
    launchPrompt(host, { projectDir: '/repo', name: 'ok', prompt: '   ' }),
    (error: unknown) => error instanceof LauncherError,
  )
})

test('a refused prompt keeps the session and reports promptAccepted=false', async () => {
  const { host, calls } = fakeHost()
  host.sessionController.prompt = async () => { throw new Error('session/agent-busy') }
  const result = await launchPrompt(host, { projectDir: '/repo', name: 'quiet', prompt: 'x' })
  assert.equal(result.promptAccepted, false)
  assert.equal(calls.created.length, 1)
})

// ── config ───────────────────────────────────────────────────────────────

test('assertValidConfig fails loud on empty roots or a bad budget', () => {
  assert.throws(() => assertValidConfig({ projectRoots: [], gitTimeoutMs: 1000 }), /non-empty array/)
  assert.throws(() => assertValidConfig({ projectRoots: [''], gitTimeoutMs: 1000 }), /non-empty string/)
  assert.throws(() => assertValidConfig({ projectRoots: ['~/Projects'], gitTimeoutMs: 0 }), /positive finite/)
  assert.doesNotThrow(() => assertValidConfig({ projectRoots: ['~/Projects'], gitTimeoutMs: 1000 }))
})
