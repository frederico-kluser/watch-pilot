window.__ModuleLoader__.load({
	id: "dsh-project-launcher",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		"use strict";
		/**
		 * Browser half of `dsh-project-launcher`: one chip in the New-Conversation
		 * overlay that lists the projects and fires a prompt in a chosen project
		 * **already inside a fresh, named worktree**.
		 *
		 * Self-contained on purpose: the file compiles to CommonJS and is wrapped in
		 * the platform's module-loader factory, so every import must be a module-table
		 * word (`react`, `@deepseek-ai/cordis`) and nothing local may leak in.
		 * @module dsh-project-launcher/client
		 */
		Object.defineProperty(exports, "__esModule", { value: true });
		exports.inject = void 0;
		exports.apply = apply;
		const react_1 = require("react");
		const LIST_ROUTE = '/dsh-projects/list';
		const LAUNCH_ROUTE = '/dsh-projects/launch';
		/** Required services: session navigation and the overlay-slot contribution. */
		exports.inject = ['sessions', 'slots'];
		/** Fetch the project inventory from the host route. */
		async function loadProjects() {
		    const response = await fetch(LIST_ROUTE, { headers: { accept: 'application/json' } });
		    if (!response.ok)
		        return [];
		    const payload = (await response.json());
		    return payload.projects ?? [];
		}
		/** Fire the launch request; the host does worktree + session + prompt. */
		async function launch(project, name, prompt) {
		    const response = await fetch(LAUNCH_ROUTE, {
		        method: 'POST',
		        headers: { 'content-type': 'application/json', accept: 'application/json' },
		        body: JSON.stringify({ project, name, prompt }),
		    });
		    return (await response.json());
		}
		/** The launcher panel: project list, worktree name, prompt. */
		function LauncherPanel(props) {
		    const [projects, setProjects] = (0, react_1.useState)([]);
		    const [project, setProject] = (0, react_1.useState)('');
		    const [name, setName] = (0, react_1.useState)('');
		    const [prompt, setPrompt] = (0, react_1.useState)('');
		    const [busy, setBusy] = (0, react_1.useState)(false);
		    const [note, setNote] = (0, react_1.useState)('');
		    (0, react_1.useEffect)(() => {
		        void loadProjects().then((found) => {
		            setProjects(found);
		            if (found.length > 0)
		                setProject(found[0].name);
		        });
		    }, []);
		    const label = { fontFamily: 'system-ui, sans-serif', fontSize: '11px', color: '#8b98a9' };
		    const field = {
		        width: '100%', boxSizing: 'border-box', marginTop: '4px', padding: '6px 8px',
		        borderRadius: '8px', border: '1px solid #2a3542', background: '#0d141c', color: '#e5eef7',
		        fontFamily: 'system-ui, sans-serif', fontSize: '12px',
		    };
		    const button = {
		        marginTop: '10px', padding: '8px 12px', borderRadius: '8px', border: 'none',
		        background: busy ? '#5b2329' : '#c8242e', color: '#fff', cursor: 'pointer',
		        fontFamily: 'system-ui, sans-serif', fontSize: '12px', fontWeight: 600,
		    };
		    return (0, react_1.createElement)('div', {
		        style: {
		            width: '320px', padding: '14px', borderRadius: '12px', background: '#111a24',
		            border: '1px solid #223041', boxShadow: '0 12px 32px rgba(0,0,0,.45)', color: '#e5eef7',
		        },
		    }, (0, react_1.createElement)('div', {
		        style: {
		            fontFamily: 'system-ui, sans-serif', fontSize: '13px', fontWeight: 700,
		            letterSpacing: '.04em', textTransform: 'uppercase', marginBottom: '10px',
		        },
		    }, 'Projetos · lançar numa worktree'), (0, react_1.createElement)('div', { style: label }, 'Projeto'), (0, react_1.createElement)('select', {
		        style: field, value: project,
		        onChange: (e) => setProject(e.target.value),
		    }, projects.map((p) => (0, react_1.createElement)('option', { key: p.path, value: p.name }, `${p.name} · ${p.branch ?? '—'} · ${p.path}`))), (0, react_1.createElement)('div', { style: { ...label, marginTop: '10px' } }, 'Nome da worktree (cria <projeto>/.worktrees/<nome>)'), (0, react_1.createElement)('input', {
		        style: field, value: name, placeholder: 'feat-minha-coisa',
		        onChange: (e) => setName(e.target.value),
		    }), (0, react_1.createElement)('div', { style: { ...label, marginTop: '10px' } }, 'Prompt a disparar nessa worktree'), (0, react_1.createElement)('textarea', {
		        style: { ...field, minHeight: '72px', resize: 'vertical' }, value: prompt,
		        placeholder: 'Arranca o trabalho neste projeto…',
		        onChange: (e) => setPrompt(e.target.value),
		    }), (0, react_1.createElement)('button', {
		        style: button, disabled: busy || project === '' || name.trim() === '' || prompt.trim() === '',
		        onClick: () => {
		            setBusy(true);
		            setNote('');
		            void launch(project, name.trim(), prompt.trim())
		                .then((result) => {
		                if (result.ok && result.sessionId !== undefined) {
		                    setNote(`worktree ${result.worktreePath} · sessão ${result.sessionId}`);
		                    props.injected.openSession(result.sessionId);
		                }
		                else {
		                    setNote(result.message ?? result.code ?? 'o lançamento foi recusado');
		                }
		            })
		                .catch((error) => setNote(error instanceof Error ? error.message : String(error)))
		                .then(() => setBusy(false));
		        },
		    }, busy ? 'A lançar…' : 'Lançar na worktree nova'), note === '' ? null : (0, react_1.createElement)('div', {
		        style: { ...label, marginTop: '8px', wordBreak: 'break-all' },
		    }, note));
		}
		/** Client plugin body: contribute the launcher chip to the overlay slot. */
		function apply(ctx) {
		    const injected = {
		        openSession(sessionId) {
		            const uiWorkspace = ctx.get('uiWorkspace');
		            if (uiWorkspace?.openSession !== undefined) {
		                uiWorkspace.openSession(sessionId);
		                return;
		            }
		            const sessions = ctx.get('sessions');
		            sessions?.open?.(sessionId);
		        },
		    };
		    const slots = ctx.slots;
		    ctx.effect(() => {
		        const dispose = slots.inject('conversation.input.overlay', () => slots.register({
		            name: 'conversation.input.overlay',
		            id: 'project-launcher',
		            order: 6,
		            inject: () => ({ hooks: { openSession: injected.openSession } }),
		        }, () => (0, react_1.createElement)(LauncherPanel, { injected })));
		        return typeof dispose === 'function' ? dispose : () => { };
		    }, 'dsh-project-launcher: overlay chip');
		}
		
		return module.exports; }
});
