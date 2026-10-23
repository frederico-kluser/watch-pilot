/**
 * Git operations for the launcher, executed through one injected runner (the
 * composition's `ctx.subprocess` in production, a stub in tests). Every
 * invocation is time-boxed and failure is reported with the git message.
 * @module dsh-project-launcher/git
 */
import type { WorktreePlan } from './worktree.ts';
/** Result of one process run. */
export interface RunResult {
    readonly code: number;
    readonly stdout: string;
    readonly stderr: string;
}
/** Injected process runner (node:child_process shape, narrowed). */
export interface Runner {
    run(command: string[], options: {
        cwd?: string;
        timeoutMs: number;
    }): Promise<RunResult>;
}
/** Filesystem seam for the exclude-file maintenance. */
export interface GitFileFs {
    readFile(path: string): string | undefined;
    writeFile(path: string, content: string): void;
    mkdirp(path: string): void;
}
/** Repository facts the planner needs. */
export interface RepoFacts {
    readonly root: string;
    readonly gitDir: string;
}
/**
 * Read the repository facts of one directory.
 * @param runner - process runner.
 * @param dir - candidate project directory.
 * @param timeoutMs - per-command budget.
 * @returns the working-tree root and the main `.git` directory.
 * @throws {LauncherError} not-git-repo when `dir` is not inside a repository.
 */
export declare function repoFacts(runner: Runner, dir: string, timeoutMs: number): Promise<RepoFacts>;
/**
 * Whether a branch name already exists in the repository.
 * @param runner - process runner.
 * @param dir - repository directory.
 * @param branch - branch to probe.
 * @param timeoutMs - per-command budget.
 * @returns true when the ref resolves.
 */
export declare function branchExists(runner: Runner, dir: string, branch: string, timeoutMs: number): Promise<boolean>;
/**
 * Whether a worktree directory already exists on disk.
 * @param runner - process runner.
 * @param dir - repository directory.
 * @param path - candidate worktree path.
 * @param timeoutMs - per-command budget.
 * @returns true when `git worktree list` already knows the path.
 */
export declare function worktreeExists(runner: Runner, dir: string, path: string, timeoutMs: number): Promise<boolean>;
/**
 * Create the planned worktree (branch + checkout) and keep the worktree root
 * out of `git status` through `.git/info/exclude`.
 *
 * The `git worktree add` MUST run with the target repository as cwd: running it
 * from the host process's cwd registers the worktree on whatever repository
 * happens to own that directory (measured: it attached to the harness checkout).
 * @param runner - process runner.
 * @param fs - file seam for the exclude file.
 * @param plan - the worktree plan.
 * @param repoRoot - absolute root of the repository the worktree belongs to.
 * @param timeoutMs - per-command budget.
 * @throws {LauncherError} launch-failed when git refuses the creation.
 */
export declare function createWorktree(runner: Runner, fs: GitFileFs, plan: WorktreePlan, repoRoot: string, timeoutMs: number): Promise<void>;
