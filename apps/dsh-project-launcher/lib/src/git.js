/**
 * Git operations for the launcher, executed through one injected runner (the
 * composition's `ctx.subprocess` in production, a stub in tests). Every
 * invocation is time-boxed and failure is reported with the git message.
 * @module dsh-project-launcher/git
 */
import { LauncherError } from "./shared.js";
import { withExcludeEntry } from "./worktree.js";
/**
 * Read the repository facts of one directory.
 * @param runner - process runner.
 * @param dir - candidate project directory.
 * @param timeoutMs - per-command budget.
 * @returns the working-tree root and the main `.git` directory.
 * @throws {LauncherError} not-git-repo when `dir` is not inside a repository.
 */
export async function repoFacts(runner, dir, timeoutMs) {
    const root = await git(runner, ['rev-parse', '--show-toplevel'], dir, timeoutMs);
    const gitDir = await git(runner, ['rev-parse', '--absolute-git-dir'], dir, timeoutMs);
    return { root: root.trim(), gitDir: gitDir.trim() };
}
/**
 * Whether a branch name already exists in the repository.
 * @param runner - process runner.
 * @param dir - repository directory.
 * @param branch - branch to probe.
 * @param timeoutMs - per-command budget.
 * @returns true when the ref resolves.
 */
export async function branchExists(runner, dir, branch, timeoutMs) {
    const result = await runner.run(['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`], { cwd: dir, timeoutMs });
    return result.code === 0 && result.stdout.trim() !== '';
}
/**
 * Whether a worktree directory already exists on disk.
 * @param runner - process runner.
 * @param dir - repository directory.
 * @param path - candidate worktree path.
 * @param timeoutMs - per-command budget.
 * @returns true when `git worktree list` already knows the path.
 */
export async function worktreeExists(runner, dir, path, timeoutMs) {
    const listed = await git(runner, ['worktree', 'list', '--porcelain'], dir, timeoutMs);
    return listed.split('\n').some((line) => line.trim() === `worktree ${path}`);
}
/**
 * Create the planned worktree (branch + checkout) and keep the worktree root
 * out of `git status` through `.git/info/exclude`.
 * @param runner - process runner.
 * @param fs - file seam for the exclude file.
 * @param plan - the worktree plan.
 * @param timeoutMs - per-command budget.
 * @throws {LauncherError} launch-failed when git refuses the creation.
 */
export async function createWorktree(runner, fs, plan, timeoutMs) {
    fs.mkdirp(plan.worktreeRoot);
    await git(runner, ['worktree', 'add', plan.worktreePath, '-b', plan.branch], undefined, timeoutMs);
    if (plan.excludeEntry !== null) {
        const current = fs.readFile(plan.excludeFile);
        fs.writeFile(plan.excludeFile, withExcludeEntry(current, plan.excludeEntry));
    }
}
/** Run one git command, translating failure into a structured launcher error. */
async function git(runner, args, cwd, timeoutMs) {
    const argv = cwd === undefined ? [...args] : ['-C', cwd, ...args];
    const result = await runner.run(argv, { cwd, timeoutMs });
    if (result.code !== 0) {
        throw new LauncherError('launch-failed', `git ${args.join(' ')} failed: ${(result.stderr || result.stdout).trim().slice(0, 300)}`);
    }
    return result.stdout;
}
