/**
 * `dsh-project-launcher` — know which projects exist and where they are, and
 * fire new prompts in them **already inside a fresh, named git worktree**.
 *
 * Two surfaces, one core:
 *  - **tools** (`ctx.tools`): `projects_list` and `projects_launch`, so an
 *    agent working in a DSH conversation can inventory the projects and open a
 *    new one-shot session inside a worktree;
 *  - **HTTP routes** (`ctx.webServer`, behind the composition's trust fence):
 *    the same capability for UI panels and scripts.
 *
 * The plugin never crashes the boot: every service is read defensively, and a
 * missing capability leaves the corresponding surface unavailable instead of
 * failing the composition.
 * @module dsh-project-launcher
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { LauncherError, PROJECTS_LAUNCH_ROUTE, PROJECTS_LIST_ROUTE } from './shared.ts'
import { expandPath, findProject, scanProjects, type FsLike, type GitFactsRunner } from './projects.ts'
import { launchPrompt, type LaunchHost } from './launch.ts'
import { HubClient } from './hub.ts'
import { startLaunchRunner } from './runner.ts'
import { startActivityPublisher, type EventsLike, type SessionsLike } from './activity.ts'
import type { GitFileFs, Runner } from './git.ts'

export const name = 'dsh-project-launcher'
export const inject = ['webServer', 'connection', 'subprocess', 'sessionController', 'agents', 'agentDefaultModel']

/** Deployment configuration. */
export interface Config {
  /** Roots to scan for projects; a leading `~` expands to the user home. */
  projectRoots: string[]
  /** Optional explicit worktree root (default `<repo>/.worktrees`). */
  worktreeRoot?: string
  /** Per-git-command budget in milliseconds. */
  gitTimeoutMs: number
}

const DEFAULT_CONFIG: Config = {
  projectRoots: ['~/Projects', '/Volumes/Ext2TB/Projects'],
  gitTimeoutMs: 30_000,
}

/** Fail loud at load: invalid config is a deployment error, never a surprise. */
export function assertValidConfig(config: Config): void {
  if (!Array.isArray(config.projectRoots) || config.projectRoots.length === 0) {
    throw new Error('dsh-project-launcher: config.projectRoots must be a non-empty array of directories')
  }
  for (const root of config.projectRoots) {
    if (typeof root !== 'string' || root.trim() === '') {
      throw new Error('dsh-project-launcher: every projectRoots entry must be a non-empty string')
    }
  }
  if (!Number.isFinite(config.gitTimeoutMs) || config.gitTimeoutMs <= 0) {
    throw new Error('dsh-project-launcher: config.gitTimeoutMs must be a positive finite number')
  }
}

// ── Host adapters ─────────────────────────────────────────────────────────

/** Offset-based collected reader, narrowed from `SubprocessOutputReader`. */
interface OutputReaderLike {
  readFrom(fromByte: number): { text: string }
}

/** One live subprocess, narrowed to what the runner reads. */
interface SubprocessHandleLike {
  readonly collected: { readonly stdout?: OutputReaderLike; readonly stderr?: OutputReaderLike }
  readonly done: Promise<{ exitCode: number | null; signal: string | null }>
  terminate(): void
}

/** Spawn spec, narrowed from `SubprocessSpawnSpec`. */
interface SubprocessSpawnSpecLike {
  argv: string[]
  cwd?: string
  stdio?: unknown
  graceMs?: number
  signal?: AbortSignal
  env?: Record<string, string>
}

/** The composition's subprocess runtime, narrowed. */
interface SubprocessRuntimeLike {
  spawn(spec: SubprocessSpawnSpecLike): SubprocessHandleLike
}

/** Build the git runner over the composition's managed subprocess runtime. */
export function runnerFrom(subprocess: SubprocessRuntimeLike): Runner {
  return {
    async run(command, options) {
      const abort = new AbortController()
      const timer = setTimeout(() => { abort.abort() }, options.timeoutMs)
      try {
        const child = subprocess.spawn({
          argv: ['git', ...command],
          // The runtime reads `spec.cwd` (never undefined): default to this process.
          cwd: options.cwd ?? process.cwd(),
          stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 20 }, stderr: { maxBytes: 1 << 16 } },
          graceMs: 2_000,
          signal: abort.signal,
          // git must never stop and wait for a human.
          env: { GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' },
        })
        const outcome = await child.done
        return {
          code: outcome.exitCode ?? 1,
          stdout: child.collected.stdout?.readFrom(0).text ?? '',
          stderr: child.collected.stderr?.readFrom(0).text ?? '',
        }
      } finally {
        clearTimeout(timer)
      }
    },
  }
}

/** Filesystem seam over node:fs (the exclude-file maintenance). */
export const gitFileFs: GitFileFs = {
  readFile(path) {
    try { return readFileSync(path, 'utf8') } catch { return undefined }
  },
  writeFile(path, content) {
    mkdirSync(join(path, '..'), { recursive: true })
    writeFileSync(path, content, 'utf8')
  },
  mkdirp(path) {
    mkdirSync(path, { recursive: true })
  },
}

/** Project-inventory filesystem seam over node:fs. */
export const projectFs: FsLike = {
  existsSync,
  isDirectory(path) { try { return statSync(path).isDirectory() } catch { return false } },
  readdir(path) { try { return readdirSync(path) } catch { return [] } },
  homedir,
}

// ── Cordis wiring ─────────────────────────────────────────────────────────

/** Service slices the plugin reads, all optional in non-web compositions. */
interface ContextLike {
  get(name: string): unknown
  effect(disposer: () => void | (() => void), label?: string): void
  webServer?: {
    register(route: {
      kind: 'exact' | 'prefix'
      path: string
      handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
    }): () => void
  }
  connection?: {
    requestRejection(request: { headers: IncomingMessage['headers'] }): 401 | 403 | undefined
  }
  subprocess?: SubprocessRuntimeLike
  sessionController?: LaunchHost['sessionController']
  agents?: LaunchHost['agents']
  agentDefaultModel?: LaunchHost['agentDefaultModel']
}

export function apply(ctx: ContextLike, config: Config = DEFAULT_CONFIG): void {
  assertValidConfig({ ...DEFAULT_CONFIG, ...config })

  // Services are read through `get()`: direct property access throws
  // "cannot get property … without inject" for anything not declared there.
  const tools = ctx.get('tools') as { register(definition: unknown): unknown } | undefined
  const webServer = ctx.webServer ?? (ctx.get('webServer') as ContextLike['webServer'])
  const connection = ctx.connection ?? (ctx.get('connection') as ContextLike['connection'])
  const subprocess = ctx.subprocess ?? (ctx.get('subprocess') as SubprocessRuntimeLike | undefined)
  const sessionController = ctx.sessionController
    ?? (ctx.get('sessionController') as LaunchHost['sessionController'] | undefined)
  const agents = ctx.agents ?? (ctx.get('agents') as LaunchHost['agents'] | undefined)
  const agentDefaultModel = ctx.agentDefaultModel
    ?? (ctx.get('agentDefaultModel') as LaunchHost['agentDefaultModel'] | undefined)

  if (subprocess === undefined || connection === undefined || webServer === undefined) {
    throw new Error(
      'dsh-project-launcher: a required service (webServer, connection, subprocess) is missing; '
      + 'this plugin activates in the web composition',
    )
  }

  const runner = runnerFrom(subprocess)
  const roots = config.projectRoots ?? DEFAULT_CONFIG.projectRoots
  const gitTimeoutMs = config.gitTimeoutMs ?? DEFAULT_CONFIG.gitTimeoutMs

  /** Shared inventory read: which projects exist and where they are. */
  const inventory = async () => {
    const facts: GitFactsRunner = {
      async branch(dir) {
        const result = await runner.run(['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD'], { cwd: dir, timeoutMs: gitTimeoutMs })
        const value = result.stdout.trim()
        return result.code === 0 && value !== '' && value !== 'HEAD' ? value : null
      },
      async lastCommit(dir) {
        const result = await runner.run(['-C', dir, 'log', '-1', '--format=%cI'], { cwd: dir, timeoutMs: gitTimeoutMs })
        return result.code === 0 ? result.stdout.trim() || null : null
      },
      async worktrees(dir) {
        const result = await runner.run(['-C', dir, 'worktree', 'list', '--porcelain'], { cwd: dir, timeoutMs: gitTimeoutMs })
        return result.stdout
          .split('\n')
          .filter((line) => line.startsWith('worktree '))
          .map((line) => line.slice('worktree '.length).trim())
      },
    }
    return scanProjects(roots, projectFs, facts)
  }

  const launchHost: LaunchHost | undefined =
    sessionController !== undefined && agents !== undefined && agentDefaultModel !== undefined
      ? { runner, fs: gitFileFs, sessionController, agents, agentDefaultModel }
      : undefined

  // ── Tools (the agent surface) ──────────────────────────────────────────
  if (tools !== undefined) {
    tools.register({
      name: 'projects_list',
      description: 'List the known projects: name, absolute path, branch, worktrees and last commit.',
      parameters: {},
      output: {
        schema: { type: 'string' },
        render(_args: unknown, value: unknown) {
          return [{ type: 'text', text: String(value) }]
        },
      },
      async execute() {
        const projects = await inventory()
        return JSON.stringify({ ok: true, roots, projects }, null, 2)
      },
    })
    tools.register({
      name: 'projects_launch',
      description:
        'Fire a new prompt in a project ALREADY INSIDE a fresh, named git worktree: '
        + 'creates <project>/.worktrees/<name> (branch <name>), opens a new session there and admits the prompt.',
      parameters: {
        project: { type: 'string', required: true, description: 'Project name or absolute path.' },
        name: { type: 'string', required: true, description: 'Worktree/branch name (letters, digits, . _ -).' },
        prompt: { type: 'string', required: true, description: 'The prompt to fire in the new session.' },
      },
      output: {
        schema: { type: 'string' },
        render(_args: unknown, value: unknown) {
          return [{ type: 'text', text: String(value) }]
        },
      },
      async execute(args: { project: string; name: string; prompt: string }) {
        if (launchHost === undefined) {
          return JSON.stringify({ ok: false, code: 'launch-failed', message: 'session services unavailable' })
        }
        try {
          const projects = await inventory()
          const project = findProject(projects, expandPath(args.project, homedir()))
          if (project === undefined) {
            return JSON.stringify({ ok: false, code: 'not-git-repo', message: `project "${args.project}" not found` })
          }
          const result = await launchPrompt(launchHost, {
            projectDir: project.path,
            name: args.name,
            prompt: args.prompt,
            worktreeRoot: config.worktreeRoot,
            timeoutMs: gitTimeoutMs,
          })
          return JSON.stringify({ ok: true, ...result })
        } catch (error) {
          const launcher = error instanceof LauncherError ? error : undefined
          return JSON.stringify({
            ok: false,
            code: launcher?.code ?? 'launch-failed',
            message: error instanceof Error ? error.message : String(error),
          })
        }
      },
    })
  }

  // ── HTTP routes (the UI/script surface) ────────────────────────────────
  const sendJson = (res: ServerResponse, status: number, payload: unknown): void => {
    res.statusCode = status
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.setHeader('cache-control', 'no-store')
    res.end(JSON.stringify(payload))
  }

  /** Trust fence first: Host/Origin + browser authentication, then logic. */
  const rejected = (req: IncomingMessage, res: ServerResponse): boolean => {
    const rejection = connection!.requestRejection(req)
    if (rejection === undefined) return false
    res.statusCode = rejection
    res.end()
    return true
  }

  const disposeList = webServer.register({
    kind: 'exact',
    path: PROJECTS_LIST_ROUTE,
    async handler(req, res) {
      if (req.method !== 'GET') {
        res.statusCode = 405
        res.setHeader('allow', 'GET')
        res.end()
        return
      }
      if (rejected(req, res)) return
      try {
        sendJson(res, 200, { ok: true, roots, projects: await inventory() })
      } catch (error) {
        sendJson(res, 500, { ok: false, message: error instanceof Error ? error.message : String(error) })
      }
    },
  })

  const disposeLaunch = webServer.register({
    kind: 'exact',
    path: PROJECTS_LAUNCH_ROUTE,
    async handler(req, res) {
      if (req.method !== 'POST') {
        res.statusCode = 405
        res.setHeader('allow', 'POST')
        res.end()
        return
      }
      if (rejected(req, res)) return
      let raw = ''
      for await (const chunk of req as AsyncIterable<Buffer>) {
        raw += chunk.toString('utf8')
        if (raw.length > 64 * 1024) break
      }
      let body: { project?: unknown; name?: unknown; prompt?: unknown }
      try {
        body = JSON.parse(raw) as typeof body
      } catch {
        sendJson(res, 400, { ok: false, code: 'invalid-name', message: 'body must be JSON' })
        return
      }
      const project = typeof body.project === 'string' ? body.project : ''
      const name = typeof body.name === 'string' ? body.name : ''
      const prompt = typeof body.prompt === 'string' ? body.prompt : ''
      if (project === '' || name === '' || prompt.trim() === '') {
        sendJson(res, 400, { ok: false, code: 'invalid-name', message: 'project, name and prompt are required' })
        return
      }
      if (launchHost === undefined) {
        sendJson(res, 503, { ok: false, code: 'launch-failed', message: 'session services unavailable' })
        return
      }
      try {
        const projects = await inventory()
        const found = findProject(projects, expandPath(project, homedir()))
        if (found === undefined) {
          sendJson(res, 404, { ok: false, code: 'not-git-repo', message: `project "${project}" not found` })
          return
        }
        const result = await launchPrompt(launchHost, {
          projectDir: found.path,
          name,
          prompt,
          worktreeRoot: config.worktreeRoot,
          timeoutMs: gitTimeoutMs,
        })
        sendJson(res, 200, { ok: true, ...result })
      } catch (error) {
        const launcher = error instanceof LauncherError ? error : undefined
        const status = launcher?.code === 'invalid-name' ? 400
          : launcher?.code === 'not-git-repo' ? 404
            : launcher?.code === 'worktree-exists' || launcher?.code === 'branch-exists' ? 409
              : 502
        sendJson(res, status, {
          ok: false,
          code: launcher?.code ?? 'launch-failed',
          message: error instanceof Error ? error.message : String(error),
        })
      }
    },
  })

  ctx.effect(() => () => {
    disposeList()
    disposeLaunch()
  }, 'dsh-project-launcher: routes')

  // ── Phone chain: drain the hub queue + publish live activity ───────────
  // Invisible by design: no UI, no slot, no client bundle. The plugin only
  // turns `watch.kluser.me` launch requests into worktree sessions and mirrors
  // the harness's live activity back to the hub for the phone to read.
  const sessions = ctx.get('sessions') as SessionsLike | undefined
  const disposers: Array<() => void> = []
  if (launchHost !== undefined) {
    try {
      const hub = HubClient.live()
      process.stderr.write('[dsh-project-launcher] phone chain ON (polling the hub launch queue)\n')
      disposers.push(startLaunchRunner({
        hub,
        host: launchHost,
        projects: inventory,
        worktreeRoot: config.worktreeRoot,
        timeoutMs: gitTimeoutMs,
      }))
      const events = ctx as unknown as EventsLike
      if (sessions !== undefined && typeof sessions.list === 'function' && typeof events.on === 'function') {
        disposers.push(startActivityPublisher({ hub, sessions, events }))
      } else {
        process.stderr.write('[dsh-project-launcher] activity publisher OFF (no sessions store or events)\n')
      }
    } catch (error) {
      // No pairing secret on this machine: routes and tools still work; the
      // phone chain simply stays off until the hub is paired.
      process.stderr.write(
        `[dsh-project-launcher] phone chain OFF: ${error instanceof Error ? error.message : String(error)}\n`,
      )
    }
  }
  ctx.effect(() => () => {
    for (const dispose of disposers) dispose()
  }, 'dsh-project-launcher: phone chain')
}
