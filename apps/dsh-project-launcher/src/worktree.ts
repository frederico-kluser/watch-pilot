/**
 * Pure worktree planning: name grammar, path composition, and the
 * `.git/info/exclude` maintenance rule. Decisions only — every effect lives in
 * `git.ts`/`launch.ts`, so tests pin this without a repository.
 * @module dsh-project-launcher/worktree
 */

import { isAbsolute, join, relative } from 'node:path'
import { LauncherError, WORKTREE_NAME_PATTERN } from './shared.ts'

/** Directory (inside the repository) this plugin creates worktrees under. */
export const DEFAULT_WORKTREE_DIRNAME = '.worktrees'

/** One planned worktree creation. */
export interface WorktreePlan {
  /** Absolute worktree root (the directory worktrees live under). */
  readonly worktreeRoot: string
  /** Absolute worktree directory (`git worktree add` target). */
  readonly worktreePath: string
  /** Branch to create and check out (the validated name). */
  readonly branch: string
  /** Exclude entry keeping the worktree root out of `git status`, or null. */
  readonly excludeEntry: string | null
  /** Absolute `.git/info/exclude` path of the main worktree. */
  readonly excludeFile: string
}

/**
 * Validate one requested worktree name.
 * @param name - raw caller-supplied name.
 * @returns the validated name.
 * @throws {LauncherError} invalid-name when the grammar rejects it.
 */
export function validateWorktreeName(name: string): string {
  const trimmed = (name ?? '').trim()
  if (!WORKTREE_NAME_PATTERN.test(trimmed) || trimmed === '.' || trimmed === '..') {
    throw new LauncherError(
      'invalid-name',
      `invalid worktree name "${name}": use 1–64 characters, letter or digit first, `
      + 'then letters, digits, dots, underscores, or hyphens; no slashes or spaces',
    )
  }
  return trimmed
}

/**
 * Plan one worktree creation.
 *
 * The default root is `<repoRoot>/.worktrees`, kept out of `git status` through
 * the repository-local `.git/info/exclude` (no tracked file is ever touched).
 * @param repoRoot - absolute repository working-tree root.
 * @param gitDir - absolute main-worktree `.git` directory.
 * @param name - validated worktree name.
 * @param configuredRoot - explicit worktree root, or undefined for the default.
 * @returns the creation plan.
 */
export function planWorktree(
  repoRoot: string,
  gitDir: string,
  name: string,
  configuredRoot?: string,
): WorktreePlan {
  const worktreeRoot = configuredRoot ?? join(repoRoot, DEFAULT_WORKTREE_DIRNAME)
  const worktreePath = join(worktreeRoot, name)
  const rel = relative(repoRoot, worktreeRoot)
  const insideRepo = rel !== '' && !rel.startsWith('..') && !isAbsolute(rel)
  return {
    worktreeRoot,
    worktreePath,
    branch: name,
    excludeEntry: insideRepo ? rel.split('\\').join('/') + '/' : null,
    excludeFile: join(gitDir, 'info', 'exclude'),
  }
}

/**
 * Build the exclude-file text after appending the entry (idempotent), keeping
 * the trailing-newline shape and adding one provenance comment.
 * @param content - current exclude text, or undefined when the file is absent.
 * @param entry - the directory entry with a trailing slash.
 * @returns the complete new file text; unchanged when already present.
 */
export function withExcludeEntry(content: string | undefined, entry: string): string {
  const current = content ?? ''
  if (current.split('\n').some((line) => line.trim() === entry)) return current
  const marker = '# added by dsh-project-launcher (created worktrees live here)'
  if (current.trim() === '') return `${marker}\n${entry}\n`
  const needsNewline = !current.endsWith('\n')
  return `${current}${needsNewline ? '\n' : ''}${marker}\n${entry}\n`
}
