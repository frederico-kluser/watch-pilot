/**
 * Shared contracts of `dsh-project-launcher`: route paths, name grammar, and
 * the wire types every surface (tools, HTTP, UI) agrees on.
 * @module dsh-project-launcher/shared
 */
/** Route: inventory of projects (GET) — "which projects do we have and where". */
export declare const PROJECTS_LIST_ROUTE = "/dsh-projects/list";
/** Route: launch a prompt in a fresh worktree (POST). */
export declare const PROJECTS_LAUNCH_ROUTE = "/dsh-projects/launch";
/**
 * Worktree/branch name grammar: 1–64 characters, letter or digit first, then
 * letters, digits, dots, underscores, or hyphens. No slashes, no spaces.
 */
export declare const WORKTREE_NAME_PATTERN: RegExp;
/** One project found under a configured root. */
export interface ProjectInfo {
    /** Directory name (the project's identity in the inventory). */
    readonly name: string;
    /** Absolute path of the project's working tree. */
    readonly path: string;
    /** Current branch of the main worktree, or null outside a branch. */
    readonly branch: string | null;
    /** Absolute paths of existing worktrees (main worktree excluded). */
    readonly worktrees: readonly string[];
    /** ISO-8601 timestamp of the last commit, or null when unborn. */
    readonly lastCommit: string | null;
}
/** One launched prompt. */
export interface LaunchResult {
    /** Session created inside the worktree. */
    readonly sessionId: string;
    /** Absolute path of the created worktree (the session's workspace). */
    readonly worktreePath: string;
    /** Branch created for the worktree. */
    readonly branch: string;
    /** Whether the prompt reached the session inbox. */
    readonly promptAccepted: boolean;
}
/** Structured failure the surfaces translate to HTTP 4xx/5xx. */
export declare class LauncherError extends Error {
    readonly code: 'invalid-name' | 'not-git-repo' | 'worktree-exists' | 'branch-exists' | 'no-roots' | 'launch-failed';
    constructor(code: 'invalid-name' | 'not-git-repo' | 'worktree-exists' | 'branch-exists' | 'no-roots' | 'launch-failed', message: string);
}
