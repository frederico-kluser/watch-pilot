/**
 * Launch orchestration: fire a new prompt in a project **already inside a fresh,
 * named worktree**.
 *
 * The sequence is the whole product: plan the worktree → create it with git →
 * create a Session whose workspace is the worktree → admit the prompt into that
 * Session. Every host capability is injected, so the orchestration is tested
 * without a harness.
 * @module dsh-project-launcher/launch
 */
import { randomUUID } from 'node:crypto';
import { LauncherError } from "./shared.js";
import { validateWorktreeName, planWorktree } from "./worktree.js";
import { branchExists, createWorktree, repoFacts, worktreeExists, } from "./git.js";
/**
 * Fire one prompt in a project, inside a brand new named worktree.
 * @param host - injected composition capabilities.
 * @param request - the launch request.
 * @returns the created session and worktree identity.
 * @throws {LauncherError} for every refusal, before or during the launch.
 */
export async function launchPrompt(host, request) {
    const timeoutMs = request.timeoutMs ?? 30_000;
    const branch = validateWorktreeName(request.name);
    const prompt = (request.prompt ?? '').trim();
    if (prompt === '') {
        throw new LauncherError('invalid-name', 'prompt must include non-whitespace text');
    }
    const facts = await repoFacts(host.runner, request.projectDir, timeoutMs);
    const plan = planWorktree(facts.root, facts.gitDir, branch, request.worktreeRoot);
    if (await worktreeExists(host.runner, facts.root, plan.worktreePath, timeoutMs)) {
        throw new LauncherError('worktree-exists', `worktree "${plan.worktreePath}" already exists`);
    }
    if (await branchExists(host.runner, facts.root, plan.branch, timeoutMs)) {
        throw new LauncherError('branch-exists', `branch "${plan.branch}" already exists`);
    }
    await createWorktree(host.runner, host.fs, plan, timeoutMs);
    const sessionId = `session-${randomUUID()}`;
    const { provider, model } = host.agentDefaultModel.currentSelection();
    await host.agents.create({
        sessionId,
        meta: { cwd: plan.worktreePath },
        agentOptions: { provider, model },
    });
    let promptAccepted = false;
    try {
        const receipt = await host.sessionController.prompt({
            requestId: `request-${randomUUID()}`,
            sessionId,
            mode: 'queue',
            content: [{ type: 'text', text: prompt }],
        });
        promptAccepted = receipt?.accepted !== false;
    }
    catch {
        // The Session exists inside the worktree even when prompt admission is
        // refused (busy/queued policies): the caller still gets a usable session.
        promptAccepted = false;
    }
    return {
        sessionId,
        worktreePath: plan.worktreePath,
        branch: plan.branch,
        promptAccepted,
    };
}
