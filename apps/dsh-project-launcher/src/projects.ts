/**
 * Project inventory: which projects exist and where they are.
 *
 * A "project" is a git working tree sitting directly under one of the
 * configured roots. The scan is pure directory work plus one `git` probe per
 * project, and every dependency is injectable so tests run without a disk.
 * @module dsh-project-launcher/projects
 */

import type { ProjectInfo } from './shared.ts'

/** Narrowed filesystem surface (node:fs), injectable for tests. */
export interface FsLike {
  existsSync(path: string): boolean
  isDirectory(path: string): boolean
  readdir(path: string): string[]
  homedir(): string
}

/** One `git` probe: the launcher only reads facts here. */
export interface GitFactsRunner {
  /** Current branch of `dir`'s main worktree (null when detached/unborn). */
  branch(dir: string): Promise<string | null>
  /** ISO-8601 timestamp of the last commit (null when unborn). */
  lastCommit(dir: string): Promise<string | null>
  /** Absolute paths of `dir`'s worktrees (main worktree included by git). */
  worktrees(dir: string): Promise<string[]>
}

/** Expand a leading `~` to the user home; leave absolute paths untouched. */
export function expandPath(value: string, home: string): string {
  const trimmed = value.trim()
  if (trimmed === '~') return home
  if (trimmed.startsWith('~/')) return `${home}${trimmed.slice(1)}`
  return trimmed
}

/**
 * Scan the configured roots for git projects.
 * @param roots - root directories to scan (a leading `~` is expanded).
 * @param fs - filesystem surface.
 * @param git - git facts runner.
 * @returns one entry per project, sorted by name.
 */
export async function scanProjects(
  roots: readonly string[],
  fs: FsLike,
  git: GitFactsRunner,
): Promise<ProjectInfo[]> {
  const home = fs.homedir()
  const found: ProjectInfo[] = []
  const seen = new Set<string>()
  for (const root of roots) {
    const absoluteRoot = expandPath(root, home)
    if (!absoluteRoot || !fs.existsSync(absoluteRoot) || !fs.isDirectory(absoluteRoot)) continue
    for (const entry of fs.readdir(absoluteRoot)) {
      const path = `${absoluteRoot}/${entry}`
      if (seen.has(path) || !fs.isDirectory(path)) continue
      // A project is a git working tree: the `.git` marker is a file (linked
      // worktree) or a directory (main worktree).
      if (!fs.existsSync(`${path}/.git`)) continue
      seen.add(path)
      const [branch, lastCommit, worktrees] = await Promise.all([
        git.branch(path),
        git.lastCommit(path),
        git.worktrees(path),
      ])
      found.push({
        name: entry,
        path,
        branch,
        worktrees: worktrees.filter((candidate) => candidate !== path),
        lastCommit,
      })
    }
  }
  return found.sort((a, b) => a.name.localeCompare(b.name))
}

/**
 * Resolve one project by name or absolute path from an inventory scan.
 * @param projects - the scanned inventory.
 * @param selector - project name or absolute path.
 * @returns the matching project, or undefined.
 */
export function findProject(
  projects: readonly ProjectInfo[],
  selector: string,
): ProjectInfo | undefined {
  return projects.find((project) => project.name === selector || project.path === selector)
}
