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
import { type LaunchResult } from './shared.ts';
import { type GitFileFs, type Runner } from './git.ts';
/** The agents registry slice: create a Session with a workspace override. */
export interface AgentsLike {
    create(options: {
        sessionId: string;
        meta?: {
            cwd?: string;
        };
        agentOptions?: {
            provider: string;
            model: string;
        };
    }): Promise<unknown>;
}
/** The session controller slice: resume a Session and admit one prompt. */
export interface SessionControllerLike {
    /**
     * Resolve or resume the Session's Agent (the controller's contract: a prompt
     * is admitted *after* the session is resumed). Optional: older compositions
     * resume lazily inside `prompt`.
     */
    resolveAgent?(sessionId: string): Promise<unknown>;
    /** `signal` is mandatory on the real Remote — `prompt` aborts on it first. */
    prompt(request: {
        requestId: string;
        sessionId: string;
        mode: 'queue' | 'steer';
        content: readonly {
            type: 'text';
            text: string;
        }[];
    }, signal: AbortSignal): Promise<{
        accepted: boolean;
    } | unknown>;
}
/** The default model slice. */
export interface DefaultModelLike {
    currentSelection(): {
        provider: string;
        model: string;
    };
}
/** Everything the launch needs from the composition. */
export interface LaunchHost {
    readonly runner: Runner;
    readonly fs: GitFileFs;
    readonly agents: AgentsLike;
    readonly sessionController: SessionControllerLike;
    readonly agentDefaultModel: DefaultModelLike;
}
/** One launch request. */
export interface LaunchRequest {
    /** Absolute path of the project (a git working tree). */
    readonly projectDir: string;
    /** Requested worktree/branch name (validated against the grammar). */
    readonly name: string;
    /** The prompt to fire in the new Session. */
    readonly prompt: string;
    /** Optional explicit worktree root; default `<repo>/.worktrees`. */
    readonly worktreeRoot?: string;
    /** Per-git-command budget. */
    readonly timeoutMs?: number;
}
/**
 * Fire one prompt in a project, inside a brand new named worktree.
 * @param host - injected composition capabilities.
 * @param request - the launch request.
 * @returns the created session and worktree identity.
 * @throws {LauncherError} for every refusal, before or during the launch.
 */
export declare function launchPrompt(host: LaunchHost, request: LaunchRequest): Promise<LaunchResult>;
