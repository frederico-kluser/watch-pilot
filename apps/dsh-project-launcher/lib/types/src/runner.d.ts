/**
 * Launch runner: drain the hub's launch queue into worktrees.
 *
 * The phone posts a launch request (prompt + "new story or not") to
 * `watch.kluser.me`; this loop picks it up, runs it — a fresh named worktree for
 * a new story, or the project as it stands otherwise — creates the session,
 * fires the prompt and reports each milestone back so the phone is notified.
 * @module dsh-project-launcher/runner
 */
import { type ProjectInfo } from './shared.ts';
import { type LaunchHost } from './launch.ts';
import type { LaunchWire } from './hub.ts';
/** The hub slice the runner needs (narrowed for tests). */
export interface HubLike {
    pendingLaunches(): Promise<LaunchWire[]>;
    report(launchId: string, body: {
        status: string;
        detail?: string;
        worktree_path?: string;
        session_id?: string;
    }): Promise<void>;
}
/** Everything the runner needs. */
export interface RunnerDeps {
    readonly hub: HubLike;
    readonly host: LaunchHost;
    /** Resolve the project inventory at execution time. */
    readonly projects: () => Promise<ProjectInfo[]>;
    readonly worktreeRoot?: string;
    readonly timeoutMs?: number;
    readonly intervalMs?: number;
    readonly log?: (message: string) => void;
}
/** Default logger: stderr, so failures never disappear silently. */
export declare function defaultLog(message: string): void;
/**
 * Start draining the queue. Returns the disposer.
 *
 * One poll at a time: a launch is long (worktree + session + prompt) and the
 * queue is small, so serial execution keeps worktrees from piling up.
 */
export declare function startLaunchRunner(deps: RunnerDeps): () => void;
/** A story name when the phone did not pick one: `story-<slug>`. */
export declare function storyNameFor(prompt: string): string;
