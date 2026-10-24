/**
 * Launch runner: drain the hub's launch queue into worktrees.
 *
 * The phone posts a launch request (prompt + "new story or not") to
 * `watch.kluser.me`; this loop picks it up, runs it — a fresh named worktree for
 * a new story, or the project as it stands otherwise — creates the session,
 * fires the prompt and reports each milestone back so the phone is notified.
 * @module dsh-project-launcher/runner
 */
import { LauncherError } from "./shared.js";
import { launchPrompt, startPrompt } from "./launch.js";
/** Default logger: stderr, so failures never disappear silently. */
export function defaultLog(message) {
    process.stderr.write(`[dsh-project-launcher] ${message}\n`);
}
/**
 * Start draining the queue. Returns the disposer.
 *
 * One poll at a time: a launch is long (worktree + session + prompt) and the
 * queue is small, so serial execution keeps worktrees from piling up.
 */
export function startLaunchRunner(deps) {
    const intervalMs = deps.intervalMs ?? 3_000;
    const log = deps.log ?? defaultLog;
    let stopped = false;
    let busy = false;
    const tick = async () => {
        if (stopped || busy)
            return;
        busy = true;
        try {
            const queue = await deps.hub.pendingLaunches();
            for (const launch of queue) {
                if (stopped)
                    break;
                await executeOne(deps, launch, log);
            }
        }
        catch (error) {
            log(`dsh-project-launcher: poll failed: ${error instanceof Error ? error.message : String(error)}`);
        }
        finally {
            busy = false;
        }
    };
    const timer = setInterval(() => { void tick(); }, intervalMs);
    void tick();
    return () => {
        stopped = true;
        clearInterval(timer);
    };
}
/** Execute one launch request and report every milestone. */
async function executeOne(deps, launch, log) {
    const report = (status, detail, extra = {}) => deps.hub.report(launch.launch_id, { status, detail, ...extra }).catch(() => { });
    try {
        await report('running', `a preparar ${launch.project}`);
        const projects = await deps.projects();
        const project = projects.find((candidate) => candidate.name === launch.project || candidate.path === launch.project);
        if (project === undefined) {
            await report('failed', `projeto "${launch.project}" não encontrado`);
            return;
        }
        const result = launch.new_story
            ? await launchPrompt(deps.host, {
                projectDir: project.path,
                name: launch.story_name !== '' ? launch.story_name : storyNameFor(launch.prompt),
                prompt: launch.prompt,
                worktreeRoot: deps.worktreeRoot,
                timeoutMs: deps.timeoutMs,
            })
            : await startPrompt(deps.host, {
                projectDir: project.path,
                prompt: launch.prompt,
                timeoutMs: deps.timeoutMs,
            });
        await report('completed', `sessão ${result.sessionId} · ${result.worktreePath}`, { worktree_path: result.worktreePath, session_id: result.sessionId });
        log(`dsh-project-launcher: launched ${launch.launch_id} → ${result.worktreePath}`);
    }
    catch (error) {
        const code = error instanceof LauncherError ? error.code : 'launch-failed';
        await report('failed', `${code}: ${error instanceof Error ? error.message : String(error)}`);
    }
}
/** A story name when the phone did not pick one: `story-<slug>`. */
export function storyNameFor(prompt) {
    const slug = prompt
        .toLowerCase()
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 40);
    return `story-${slug === '' ? 'nova' : slug}`;
}
