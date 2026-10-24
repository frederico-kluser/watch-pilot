/**
 * Project inventory: which projects exist and where they are.
 *
 * A "project" is a git working tree sitting directly under one of the
 * configured roots. The scan is pure directory work plus one `git` probe per
 * project, and every dependency is injectable so tests run without a disk.
 * @module dsh-project-launcher/projects
 */
import type { ProjectInfo } from './shared.ts';
/** Narrowed filesystem surface (node:fs), injectable for tests. */
export interface FsLike {
    existsSync(path: string): boolean;
    isDirectory(path: string): boolean;
    readdir(path: string): string[];
    homedir(): string;
}
/** One `git` probe: the launcher only reads facts here. */
export interface GitFactsRunner {
    /** Current branch of `dir`'s main worktree (null when detached/unborn). */
    branch(dir: string): Promise<string | null>;
    /** ISO-8601 timestamp of the last commit (null when unborn). */
    lastCommit(dir: string): Promise<string | null>;
    /** Absolute paths of `dir`'s worktrees (main worktree included by git). */
    worktrees(dir: string): Promise<string[]>;
}
/** Expand a leading `~` to the user home; leave absolute paths untouched. */
export declare function expandPath(value: string, home: string): string;
/**
 * Scan the configured roots for git projects.
 * @param roots - root directories to scan (a leading `~` is expanded).
 * @param fs - filesystem surface.
 * @param git - git facts runner.
 * @returns one entry per project, sorted by name.
 */
export declare function scanProjects(roots: readonly string[], fs: FsLike, git: GitFactsRunner): Promise<ProjectInfo[]>;
/**
 * Resolve one project by name or absolute path from an inventory scan.
 * @param projects - the scanned inventory.
 * @param selector - project name or absolute path.
 * @returns the matching project, or undefined.
 */
export declare function findProject(projects: readonly ProjectInfo[], selector: string): ProjectInfo | undefined;
