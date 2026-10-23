/**
 * Shared contracts of `dsh-project-launcher`: route paths, name grammar, and
 * the wire types every surface (tools, HTTP, UI) agrees on.
 * @module dsh-project-launcher/shared
 */
/** Route: inventory of projects (GET) — "which projects do we have and where". */
export const PROJECTS_LIST_ROUTE = '/dsh-projects/list';
/** Route: launch a prompt in a fresh worktree (POST). */
export const PROJECTS_LAUNCH_ROUTE = '/dsh-projects/launch';
/**
 * Worktree/branch name grammar: 1–64 characters, letter or digit first, then
 * letters, digits, dots, underscores, or hyphens. No slashes, no spaces.
 */
export const WORKTREE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
/** Structured failure the surfaces translate to HTTP 4xx/5xx. */
export class LauncherError extends Error {
    code;
    constructor(code, message) {
        super(message);
        this.code = code;
        this.name = 'LauncherError';
    }
}
