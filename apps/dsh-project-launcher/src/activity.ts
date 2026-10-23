/**
 * Activity publisher: who is working, who is not, and what each session is
 * doing right now — the real harness telemetry `dsh-work-game` renders,
 * republished to `watch.kluser.me` so the phone sees it.
 *
 * Event surface (verified against the harness checkout, same as the
 * dsh-work-game adapter): `sessions.list()` and `sessions.on(name, handler)`
 * with `agent/status` ({agent, status}) and `session/event` (session, event).
 * @module dsh-project-launcher/activity
 */

import type { ActivityWire } from './hub.ts'

/** The hub slice the publisher needs (narrowed for tests). */
export interface HubLike {
  publishActivity(sessions: ActivityWire[]): Promise<void>
}

/** One live session row as the plugin tracks it. */
interface Tracked {
  id: string
  name: string
  state: 'running' | 'idle' | 'waiting'
  line: string
  workspace: string
  model: string
}

/** Narrowed session catalogue slice (`ctx.sessions`). */
export interface SessionsLike {
  list(): Array<{ id: string; header?: { cwd?: string; title?: string } }>
}

/**
 * Event source: on the HOST these are Cordis events (`ctx.on`), not store
 * methods — the `sessions.on` shape belongs to the browser store. Both are
 * accepted here so the publisher works either side.
 */
export interface EventsLike {
  on(event: string, handler: (...args: unknown[]) => void): () => void
}

/** Publisher options. */
export interface ActivityDeps {
  readonly hub: HubLike
  readonly sessions: SessionsLike
  /** Cordis-style events (host) — falls back to `sessions.on` when absent. */
  readonly events?: EventsLike
  readonly intervalMs?: number
  readonly log?: (message: string) => void
}

/** Default logger: stderr, so failures never disappear silently. */
export function defaultLog(message: string): void {
  process.stderr.write(`[dsh-project-launcher] ${message}\n`)
}

/** Start publishing snapshots; returns the disposer. */
export function startActivityPublisher(deps: ActivityDeps): () => void {
  const intervalMs = deps.intervalMs ?? 2_000
  const log = deps.log ?? defaultLog
  const tracked = new Map<string, Tracked>()

  const ensure = (id: string, workspace = ''): Tracked => {
    const existing = tracked.get(id)
    if (existing !== undefined) return existing
    // A human name: the workspace folder (or the worktree name) beats the raw id.
    const folder = workspace === '' ? '' : workspace.split('/').filter(Boolean).at(-1) ?? ''
    const entry: Tracked = {
      id,
      name: folder === '' ? id.slice(0, 8) : folder,
      state: 'idle',
      line: '',
      workspace,
      model: '',
    }
    tracked.set(id, entry)
    return entry
  }

  const events: EventsLike = deps.events
    ?? (deps.sessions as unknown as { on?: EventsLike['on'] }).on !== undefined
      ? (deps.events ?? (deps.sessions as unknown as EventsLike))
      : { on: () => () => {} }
  const subscribe: EventsLike['on'] = (name, handler) => events.on(name, handler)
  const seed = deps.sessions.list()
  process.stderr.write(`[dsh-project-launcher] activity publisher ON (${seed.length} sessions at start)\n`)
  for (const session of seed) {
    ensure(session.id, session.header?.cwd ?? '')
  }

  // Who is working / who is not: the harness's own agent status vocabulary.
  const offStatus = subscribe('agent/status', (...args: unknown[]) => {
    const payload = args[0] as { agent?: { session?: { id?: string } }; status?: string }
    const id = payload?.agent?.session?.id
    if (typeof id !== 'string') return
    const entry = ensure(id)
    entry.state = payload.status === 'running' ? 'running' : 'idle'
    if (payload.status !== 'running' && entry.line.startsWith('…')) entry.line = ''
  })

  // What each session is doing: the newest event becomes its live line.
  const offEvent = subscribe('session/event', (...args: unknown[]) => {
    const session = args[0] as { id?: string; header?: { cwd?: string } }
    const event = args[1] as { type?: string; data?: Record<string, unknown> }
    const id = session?.id
    if (typeof id !== 'string') return
    const entry = ensure(id, session?.header?.cwd ?? entry0(tracked, id))
    entry.line = lineOf(event)
  })

  const offCreated = subscribe('session/created', (...args: unknown[]) => {
    const session = args[0] as { id?: string; header?: { cwd?: string; title?: string } }
    if (typeof session?.id !== 'string') return
    const entry = ensure(session.id, session.header?.cwd ?? '')
    entry.name = session.header?.title ?? entry.name
  })

  const offDisposed = subscribe('session/disposed', (...args: unknown[]) => {
    const session = args[0] as { id?: string }
    if (typeof session?.id === 'string') tracked.delete(session.id)
  })

  const timer = setInterval(() => {
    const snapshot: ActivityWire[] = [...tracked.values()].map((entry) => ({
      id: entry.id,
      name: entry.name,
      state: entry.state,
      line: entry.line,
      workspace: entry.workspace,
      model: entry.model,
    }))
    void deps.hub.publishActivity(snapshot).catch((error: unknown) => {
      log(`dsh-project-launcher: activity publish failed: ${error instanceof Error ? error.message : String(error)}`)
    })
  }, intervalMs)

  return () => {
    clearInterval(timer)
    offStatus()
    offEvent()
    offCreated()
    offDisposed()
  }
}

function entry0(tracked: Map<string, Tracked>, id: string): string {
  return tracked.get(id)?.workspace ?? ''
}

/** One short human line for one session event (what the agent is doing). */
export function lineOf(event: { type?: string; data?: Record<string, unknown> }): string {
  const type = event?.type ?? ''
  const data = event?.data ?? {}
  switch (type) {
    case 'message/progress': {
      const text = typeof data['text'] === 'string' ? data['text'] : ''
      return text === '' ? '' : `… ${text.slice(-120)}`
    }
    case 'tool/call': {
      const name = typeof data['name'] === 'string' ? data['name'] : 'ferramenta'
      return `→ ${name}`
    }
    case 'tool/result':
      return '✓ ferramenta concluída'
    case 'turn/start':
      return '… a pensar'
    case 'turn/end':
      return 'turno concluído'
    default:
      return ''
  }
}
