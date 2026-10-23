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
import type { IncomingMessage, ServerResponse } from 'node:http';
import { type FsLike } from './projects.ts';
import { type LaunchHost } from './launch.ts';
import type { GitFileFs, Runner } from './git.ts';
export declare const name = "dsh-project-launcher";
export declare const inject: string[];
/** Deployment configuration. */
export interface Config {
    /** Roots to scan for projects; a leading `~` expands to the user home. */
    projectRoots: string[];
    /** Optional explicit worktree root (default `<repo>/.worktrees`). */
    worktreeRoot?: string;
    /** Per-git-command budget in milliseconds. */
    gitTimeoutMs: number;
}
/** Fail loud at load: invalid config is a deployment error, never a surprise. */
export declare function assertValidConfig(config: Config): void;
/** Offset-based collected reader, narrowed from `SubprocessOutputReader`. */
interface OutputReaderLike {
    readFrom(fromByte: number): {
        text: string;
    };
}
/** One live subprocess, narrowed to what the runner reads. */
interface SubprocessHandleLike {
    readonly collected: {
        readonly stdout?: OutputReaderLike;
        readonly stderr?: OutputReaderLike;
    };
    readonly done: Promise<{
        exitCode: number | null;
        signal: string | null;
    }>;
    terminate(): void;
}
/** Spawn spec, narrowed from `SubprocessSpawnSpec`. */
interface SubprocessSpawnSpecLike {
    argv: string[];
    cwd?: string;
    stdio?: unknown;
    graceMs?: number;
    signal?: AbortSignal;
    env?: Record<string, string>;
}
/** The composition's subprocess runtime, narrowed. */
interface SubprocessRuntimeLike {
    spawn(spec: SubprocessSpawnSpecLike): SubprocessHandleLike;
}
/** Build the git runner over the composition's managed subprocess runtime. */
export declare function runnerFrom(subprocess: SubprocessRuntimeLike): Runner;
/** Filesystem seam over node:fs (the exclude-file maintenance). */
export declare const gitFileFs: GitFileFs;
/** Project-inventory filesystem seam over node:fs. */
export declare const projectFs: FsLike;
/** Service slices the plugin reads, all optional in non-web compositions. */
interface ContextLike {
    get(name: string): unknown;
    effect(disposer: () => void | (() => void), label?: string): void;
    tools?: {
        register(definition: unknown): unknown;
    };
    webServer?: {
        register(route: {
            kind: 'exact' | 'prefix';
            path: string;
            handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>;
        }): () => void;
    };
    connection?: {
        requestRejection(request: {
            headers: IncomingMessage['headers'];
        }): 401 | 403 | undefined;
    };
    subprocess?: SubprocessRuntimeLike;
    sessionController?: LaunchHost['sessionController'];
    agents?: LaunchHost['agents'];
    agentDefaultModel?: LaunchHost['agentDefaultModel'];
}
export declare function apply(ctx: ContextLike, config?: Config): void;
export {};
