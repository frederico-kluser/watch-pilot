/**
 * Launch orchestration: fire a new prompt in a project **already inside a fresh,
 * named worktree**.
 *
 * The sequence is the whole product: plan the worktree → create it with git →
 * create a Session whose workspace is the worktree → admit the prompt into that
 * Session. Every host capability is injected, so the orchestration is tested
 * without a harness.
 * @module dsh-project-launcher/launch
 */

import { randomUUID } from 'node:crypto'
import { LauncherError, type LaunchResult } from './shared.ts'
import { validateWorktreeName, planWorktree } from './worktree.ts'
import {
  branchExists,
  createWorktree,
  repoFacts,
  worktreeExists,
  type GitFileFs,
  type Runner,
} from './git.ts'

/** The agents registry slice: create a Session with a workspace override. */
export interface AgentsLike {
  create(options: {
    sessionId: string
    meta?: { cwd?: string }
    agentOptions?: { provider: string; model: string }
  }): Promise<unknown>
}

/** The session controller slice: resume a Session and admit one prompt. */
export interface SessionControllerLike {
  /**
   * Resolve or resume the Session's Agent (the controller's contract: a prompt
   * is admitted *after* the session is resumed). Optional: older compositions
   * resume lazily inside `prompt`.
   */
  resolveAgent?(sessionId: string): Promise<unknown>
  /** `signal` is mandatory on the real Remote — `prompt` aborts on it first. */
  prompt(
    request: {
      requestId: string
      sessionId: string
      mode: 'queue' | 'steer'
      content: readonly { type: 'text'; text: string }[]
    },
    signal: AbortSignal,
  ): Promise<{ accepted: boolean } | unknown>
}

/** The default model slice. */
export interface DefaultModelLike {
  currentSelection(): { provider: string; model: string }
}

/** Everything the launch needs from the composition. */
export interface LaunchHost {
  readonly runner: Runner
  readonly fs: GitFileFs
  readonly agents: AgentsLike
  readonly sessionController: SessionControllerLike
  readonly agentDefaultModel: DefaultModelLike
}

/** One launch request. */
export interface LaunchRequest {
  /** Absolute path of the project (a git working tree). */
  readonly projectDir: string
  /** Requested worktree/branch name (validated against the grammar). */
  readonly name: string
  /** The prompt to fire in the new Session. */
  readonly prompt: string
  /** Optional explicit worktree root; default `<repo>/.worktrees`. */
  readonly worktreeRoot?: string
  /** Per-git-command budget. */
  readonly timeoutMs?: number
}

/**
 * Fire one prompt in a project AS IT STANDS (no new story/worktree): one session
 * whose workspace is the project directory, with the prompt admitted.
 * @param host - injected composition capabilities.
 * @param request - project directory and prompt (the name is unused here).
 * @returns the created session identity.
 */
export async function startPrompt(
  host: LaunchHost,
  request: { projectDir: string; prompt: string; timeoutMs?: number },
): Promise<LaunchResult> {
  const prompt = (request.prompt ?? '').trim()
  if (prompt === '') throw new LauncherError('invalid-name', 'prompt must include non-whitespace text')
  const sessionId = `session-${randomUUID()}`
  const { provider, model } = host.agentDefaultModel.currentSelection()
  await host.agents.create({
    sessionId,
    meta: { cwd: request.projectDir },
    agentOptions: { provider, model },
  })
  let promptAccepted = false
  try {
    await host.sessionController.resolveAgent?.(sessionId)
    const receipt = await host.sessionController.prompt({
      requestId: `request-${randomUUID()}`,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: prompt }],
    }, new AbortController().signal)
    promptAccepted = (receipt as { accepted?: boolean } | undefined)?.accepted !== false
  } catch {
    promptAccepted = false
  }
  return {
    sessionId,
    worktreePath: request.projectDir,
    branch: '',
    promptAccepted,
  }
}

/**
 * Fire one prompt in a project, inside a brand new named worktree.
 * @param host - injected composition capabilities.
 * @param request - the launch request.
 * @returns the created session and worktree identity.
 * @throws {LauncherError} for every refusal, before or during the launch.
 */
export async function launchPrompt(
  host: LaunchHost,
  request: LaunchRequest,
): Promise<LaunchResult> {
  const timeoutMs = request.timeoutMs ?? 30_000
  const branch = validateWorktreeName(request.name)
  const prompt = (request.prompt ?? '').trim()
  if (prompt === '') {
    throw new LauncherError('invalid-name', 'prompt must include non-whitespace text')
  }

  const facts = await repoFacts(host.runner, request.projectDir, timeoutMs)
  const plan = planWorktree(facts.root, facts.gitDir, branch, request.worktreeRoot)

  if (await worktreeExists(host.runner, facts.root, plan.worktreePath, timeoutMs)) {
    throw new LauncherError('worktree-exists', `worktree "${plan.worktreePath}" already exists`)
  }
  if (await branchExists(host.runner, facts.root, plan.branch, timeoutMs)) {
    throw new LauncherError('branch-exists', `branch "${plan.branch}" already exists`)
  }

  await createWorktree(host.runner, host.fs, plan, facts.root, timeoutMs)

  const sessionId = `session-${randomUUID()}`
  const { provider, model } = host.agentDefaultModel.currentSelection()
  await host.agents.create({
    sessionId,
    meta: { cwd: plan.worktreePath },
    agentOptions: { provider, model },
  })

  let promptAccepted = false
  try {
    // The controller admits prompts *after* the Session is resumed.
    await host.sessionController.resolveAgent?.(sessionId)
    const receipt = await host.sessionController.prompt({
      requestId: `request-${randomUUID()}`,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text: prompt }],
    }, new AbortController().signal)
    promptAccepted = (receipt as { accepted?: boolean } | undefined)?.accepted !== false
  } catch {
    // The Session exists inside the worktree even when prompt admission is
    // refused (busy/queued policies): the caller still gets a usable session.
    promptAccepted = false
  }

  return {
    sessionId,
    worktreePath: plan.worktreePath,
    branch: plan.branch,
    promptAccepted,
  }
}
