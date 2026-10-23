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
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { LauncherError, PROJECTS_LAUNCH_ROUTE, PROJECTS_LIST_ROUTE } from "./shared.js";
import { expandPath, findProject, scanProjects } from "./projects.js";
import { launchPrompt } from "./launch.js";
export const name = 'dsh-project-launcher';
export const inject = ['webServer', 'connection', 'subprocess', 'sessionController', 'agents', 'agentDefaultModel'];
const DEFAULT_CONFIG = {
    projectRoots: ['~/Projects', '/Volumes/Ext2TB/Projects'],
    gitTimeoutMs: 30_000,
};
/** Fail loud at load: invalid config is a deployment error, never a surprise. */
export function assertValidConfig(config) {
    if (!Array.isArray(config.projectRoots) || config.projectRoots.length === 0) {
        throw new Error('dsh-project-launcher: config.projectRoots must be a non-empty array of directories');
    }
    for (const root of config.projectRoots) {
        if (typeof root !== 'string' || root.trim() === '') {
            throw new Error('dsh-project-launcher: every projectRoots entry must be a non-empty string');
        }
    }
    if (!Number.isFinite(config.gitTimeoutMs) || config.gitTimeoutMs <= 0) {
        throw new Error('dsh-project-launcher: config.gitTimeoutMs must be a positive finite number');
    }
}
/** Build the git runner over the composition's managed subprocess runtime. */
export function runnerFrom(subprocess) {
    return {
        async run(command, options) {
            const abort = new AbortController();
            const timer = setTimeout(() => { abort.abort(); }, options.timeoutMs);
            try {
                const child = subprocess.spawn({
                    argv: ['git', ...command],
                    cwd: options.cwd,
                    stdio: { stdin: 'ignore', stdout: { maxBytes: 1 << 20 }, stderr: { maxBytes: 1 << 16 } },
                    graceMs: 2_000,
                    signal: abort.signal,
                    // git must never stop and wait for a human.
                    env: { GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' },
                });
                const outcome = await child.done;
                return {
                    code: outcome.exitCode ?? 1,
                    stdout: child.collected.stdout?.readFrom(0).text ?? '',
                    stderr: child.collected.stderr?.readFrom(0).text ?? '',
                };
            }
            finally {
                clearTimeout(timer);
            }
        },
    };
}
/** Filesystem seam over node:fs (the exclude-file maintenance). */
export const gitFileFs = {
    readFile(path) {
        try {
            return readFileSync(path, 'utf8');
        }
        catch {
            return undefined;
        }
    },
    writeFile(path, content) {
        mkdirSync(join(path, '..'), { recursive: true });
        writeFileSync(path, content, 'utf8');
    },
    mkdirp(path) {
        mkdirSync(path, { recursive: true });
    },
};
/** Project-inventory filesystem seam over node:fs. */
export const projectFs = {
    existsSync,
    isDirectory(path) { try {
        return statSync(path).isDirectory();
    }
    catch {
        return false;
    } },
    readdir(path) { try {
        return readdirSync(path);
    }
    catch {
        return [];
    } },
    homedir,
};
export function apply(ctx, config = DEFAULT_CONFIG) {
    assertValidConfig({ ...DEFAULT_CONFIG, ...config });
    const webServer = ctx.webServer ?? ctx.get('webServer');
    const connection = ctx.connection ?? ctx.get('connection');
    const subprocess = ctx.subprocess ?? ctx.get('subprocess');
    const sessionController = ctx.sessionController
        ?? ctx.get('sessionController');
    const agents = ctx.agents ?? ctx.get('agents');
    const agentDefaultModel = ctx.agentDefaultModel
        ?? ctx.get('agentDefaultModel');
    if (subprocess === undefined || connection === undefined || webServer === undefined) {
        throw new Error('dsh-project-launcher: a required service (webServer, connection, subprocess) is missing; '
            + 'this plugin activates in the web composition');
    }
    const runner = runnerFrom(subprocess);
    const roots = config.projectRoots ?? DEFAULT_CONFIG.projectRoots;
    const gitTimeoutMs = config.gitTimeoutMs ?? DEFAULT_CONFIG.gitTimeoutMs;
    /** Shared inventory read: which projects exist and where they are. */
    const inventory = async () => {
        const facts = {
            async branch(dir) {
                const result = await runner.run(['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD'], { cwd: dir, timeoutMs: gitTimeoutMs });
                const value = result.stdout.trim();
                return result.code === 0 && value !== '' && value !== 'HEAD' ? value : null;
            },
            async lastCommit(dir) {
                const result = await runner.run(['-C', dir, 'log', '-1', '--format=%cI'], { cwd: dir, timeoutMs: gitTimeoutMs });
                return result.code === 0 ? result.stdout.trim() || null : null;
            },
            async worktrees(dir) {
                const result = await runner.run(['-C', dir, 'worktree', 'list', '--porcelain'], { cwd: dir, timeoutMs: gitTimeoutMs });
                return result.stdout
                    .split('\n')
                    .filter((line) => line.startsWith('worktree '))
                    .map((line) => line.slice('worktree '.length).trim());
            },
        };
        return scanProjects(roots, projectFs, facts);
    };
    const launchHost = sessionController !== undefined && agents !== undefined && agentDefaultModel !== undefined
        ? { runner, fs: gitFileFs, sessionController, agents, agentDefaultModel }
        : undefined;
    // ── Tools (the agent surface) ──────────────────────────────────────────
    if (ctx.tools !== undefined) {
        const tools = ctx.tools;
        tools.register({
            name: 'projects_list',
            description: 'List the known projects: name, absolute path, branch, worktrees and last commit.',
            parameters: {},
            output: {
                schema: { type: 'string' },
                render(_args, value) {
                    return [{ type: 'text', text: String(value) }];
                },
            },
            async execute() {
                const projects = await inventory();
                return JSON.stringify({ ok: true, roots, projects }, null, 2);
            },
        });
        tools.register({
            name: 'projects_launch',
            description: 'Fire a new prompt in a project ALREADY INSIDE a fresh, named git worktree: '
                + 'creates <project>/.worktrees/<name> (branch <name>), opens a new session there and admits the prompt.',
            parameters: {
                project: { type: 'string', required: true, description: 'Project name or absolute path.' },
                name: { type: 'string', required: true, description: 'Worktree/branch name (letters, digits, . _ -).' },
                prompt: { type: 'string', required: true, description: 'The prompt to fire in the new session.' },
            },
            output: {
                schema: { type: 'string' },
                render(_args, value) {
                    return [{ type: 'text', text: String(value) }];
                },
            },
            async execute(args) {
                if (launchHost === undefined) {
                    return JSON.stringify({ ok: false, code: 'launch-failed', message: 'session services unavailable' });
                }
                try {
                    const projects = await inventory();
                    const project = findProject(projects, expandPath(args.project, homedir()));
                    if (project === undefined) {
                        return JSON.stringify({ ok: false, code: 'not-git-repo', message: `project "${args.project}" not found` });
                    }
                    const result = await launchPrompt(launchHost, {
                        projectDir: project.path,
                        name: args.name,
                        prompt: args.prompt,
                        worktreeRoot: config.worktreeRoot,
                        timeoutMs: gitTimeoutMs,
                    });
                    return JSON.stringify({ ok: true, ...result });
                }
                catch (error) {
                    const launcher = error instanceof LauncherError ? error : undefined;
                    return JSON.stringify({
                        ok: false,
                        code: launcher?.code ?? 'launch-failed',
                        message: error instanceof Error ? error.message : String(error),
                    });
                }
            },
        });
    }
    // ── HTTP routes (the UI/script surface) ────────────────────────────────
    const sendJson = (res, status, payload) => {
        res.statusCode = status;
        res.setHeader('content-type', 'application/json; charset=utf-8');
        res.setHeader('cache-control', 'no-store');
        res.end(JSON.stringify(payload));
    };
    /** Trust fence first: Host/Origin + browser authentication, then logic. */
    const rejected = (req, res) => {
        const rejection = connection.requestRejection(req);
        if (rejection === undefined)
            return false;
        res.statusCode = rejection;
        res.end();
        return true;
    };
    const disposeList = webServer.register({
        kind: 'exact',
        path: PROJECTS_LIST_ROUTE,
        async handler(req, res) {
            if (req.method !== 'GET') {
                res.statusCode = 405;
                res.setHeader('allow', 'GET');
                res.end();
                return;
            }
            if (rejected(req, res))
                return;
            try {
                sendJson(res, 200, { ok: true, roots, projects: await inventory() });
            }
            catch (error) {
                sendJson(res, 500, { ok: false, message: error instanceof Error ? error.message : String(error) });
            }
        },
    });
    const disposeLaunch = webServer.register({
        kind: 'exact',
        path: PROJECTS_LAUNCH_ROUTE,
        async handler(req, res) {
            if (req.method !== 'POST') {
                res.statusCode = 405;
                res.setHeader('allow', 'POST');
                res.end();
                return;
            }
            if (rejected(req, res))
                return;
            let raw = '';
            for await (const chunk of req) {
                raw += chunk.toString('utf8');
                if (raw.length > 64 * 1024)
                    break;
            }
            let body;
            try {
                body = JSON.parse(raw);
            }
            catch {
                sendJson(res, 400, { ok: false, code: 'invalid-name', message: 'body must be JSON' });
                return;
            }
            const project = typeof body.project === 'string' ? body.project : '';
            const name = typeof body.name === 'string' ? body.name : '';
            const prompt = typeof body.prompt === 'string' ? body.prompt : '';
            if (project === '' || name === '' || prompt.trim() === '') {
                sendJson(res, 400, { ok: false, code: 'invalid-name', message: 'project, name and prompt are required' });
                return;
            }
            if (launchHost === undefined) {
                sendJson(res, 503, { ok: false, code: 'launch-failed', message: 'session services unavailable' });
                return;
            }
            try {
                const projects = await inventory();
                const found = findProject(projects, expandPath(project, homedir()));
                if (found === undefined) {
                    sendJson(res, 404, { ok: false, code: 'not-git-repo', message: `project "${project}" not found` });
                    return;
                }
                const result = await launchPrompt(launchHost, {
                    projectDir: found.path,
                    name,
                    prompt,
                    worktreeRoot: config.worktreeRoot,
                    timeoutMs: gitTimeoutMs,
                });
                sendJson(res, 200, { ok: true, ...result });
            }
            catch (error) {
                const launcher = error instanceof LauncherError ? error : undefined;
                const status = launcher?.code === 'invalid-name' ? 400
                    : launcher?.code === 'not-git-repo' ? 404
                        : launcher?.code === 'worktree-exists' || launcher?.code === 'branch-exists' ? 409
                            : 502;
                sendJson(res, status, {
                    ok: false,
                    code: launcher?.code ?? 'launch-failed',
                    message: error instanceof Error ? error.message : String(error),
                });
            }
        },
    });
    ctx.effect(() => () => {
        disposeList();
        disposeLaunch();
    }, 'dsh-project-launcher: routes');
}
