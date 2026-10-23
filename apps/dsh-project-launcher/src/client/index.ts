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

import { createElement as h, useEffect, useState } from 'react'
import type { Context as ClientContext } from '@deepseek-ai/cordis'

/** Project inventory entry, mirrored from the host route. */
interface ProjectWire {
  name: string
  path: string
  branch: string | null
  worktrees: readonly string[]
  lastCommit: string | null
}

/** One launch receipt, mirrored from the host route. */
interface LaunchWire {
  ok: boolean
  sessionId?: string
  worktreePath?: string
  branch?: string
  promptAccepted?: boolean
  code?: string
  message?: string
}

const LIST_ROUTE = '/dsh-projects/list'
const LAUNCH_ROUTE = '/dsh-projects/launch'

/** Required services: session navigation and the overlay-slot contribution. */
export const inject = ['sessions', 'slots']

/** Fetch the project inventory from the host route. */
async function loadProjects(): Promise<ProjectWire[]> {
  const response = await fetch(LIST_ROUTE, { headers: { accept: 'application/json' } })
  if (!response.ok) return []
  const payload = (await response.json()) as { projects?: ProjectWire[] }
  return payload.projects ?? []
}

/** Fire the launch request; the host does worktree + session + prompt. */
async function launch(project: string, name: string, prompt: string): Promise<LaunchWire> {
  const response = await fetch(LAUNCH_ROUTE, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ project, name, prompt }),
  })
  return (await response.json()) as LaunchWire
}

/** The launcher panel: project list, worktree name, prompt. */
function LauncherPanel(props: { injected: InjectedHooks }): unknown {
  const [projects, setProjects] = useState([] as ProjectWire[])
  const [project, setProject] = useState('')
  const [name, setName] = useState('')
  const [prompt, setPrompt] = useState('')
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState('')

  useEffect(() => {
    void loadProjects().then((found) => {
      setProjects(found)
      if (found.length > 0) setProject(found[0].name)
    })
  }, [])

  const label = { fontFamily: 'system-ui, sans-serif', fontSize: '11px', color: '#8b98a9' }
  const field = {
    width: '100%', boxSizing: 'border-box' as const, marginTop: '4px', padding: '6px 8px',
    borderRadius: '8px', border: '1px solid #2a3542', background: '#0d141c', color: '#e5eef7',
    fontFamily: 'system-ui, sans-serif', fontSize: '12px',
  }
  const button = {
    marginTop: '10px', padding: '8px 12px', borderRadius: '8px', border: 'none',
    background: busy ? '#5b2329' : '#c8242e', color: '#fff', cursor: 'pointer',
    fontFamily: 'system-ui, sans-serif', fontSize: '12px', fontWeight: 600,
  }

  return h('div', {
    style: {
      width: '320px', padding: '14px', borderRadius: '12px', background: '#111a24',
      border: '1px solid #223041', boxShadow: '0 12px 32px rgba(0,0,0,.45)', color: '#e5eef7',
    },
  },
    h('div', {
      style: {
        fontFamily: 'system-ui, sans-serif', fontSize: '13px', fontWeight: 700,
        letterSpacing: '.04em', textTransform: 'uppercase', marginBottom: '10px',
      },
    }, 'Projetos · lançar numa worktree'),
    h('div', { style: label }, 'Projeto'),
    h('select', {
      style: field, value: project,
      onChange: (e: { target: { value: string } }) => setProject(e.target.value),
    }, projects.map((p) =>
      h('option', { key: p.path, value: p.name }, `${p.name} · ${p.branch ?? '—'} · ${p.path}`))),
    h('div', { style: { ...label, marginTop: '10px' } }, 'Nome da worktree (cria <projeto>/.worktrees/<nome>)'),
    h('input', {
      style: field, value: name, placeholder: 'feat-minha-coisa',
      onChange: (e: { target: { value: string } }) => setName(e.target.value),
    }),
    h('div', { style: { ...label, marginTop: '10px' } }, 'Prompt a disparar nessa worktree'),
    h('textarea', {
      style: { ...field, minHeight: '72px', resize: 'vertical' as const }, value: prompt,
      placeholder: 'Arranca o trabalho neste projeto…',
      onChange: (e: { target: { value: string } }) => setPrompt(e.target.value),
    }),
    h('button', {
      style: button, disabled: busy || project === '' || name.trim() === '' || prompt.trim() === '',
      onClick: () => {
        setBusy(true)
        setNote('')
        void launch(project, name.trim(), prompt.trim())
          .then((result) => {
            if (result.ok && result.sessionId !== undefined) {
              setNote(`worktree ${result.worktreePath} · sessão ${result.sessionId}`)
              props.injected.openSession(result.sessionId)
            } else {
              setNote(result.message ?? result.code ?? 'o lançamento foi recusado')
            }
          })
          .catch((error: unknown) => setNote(error instanceof Error ? error.message : String(error)))
          .then(() => setBusy(false))
      },
    }, busy ? 'A lançar…' : 'Lançar na worktree nova'),
    note === '' ? null : h('div', {
      style: { ...label, marginTop: '8px', wordBreak: 'break-all' },
    }, note),
  )
}

/** Hooks the slot injects into the panel. */
interface InjectedHooks {
  openSession(sessionId: string): void
}

/** Client plugin body: contribute the launcher chip to the overlay slot. */
export function apply(ctx: ClientContext): void {
  const injected: InjectedHooks = {
    openSession(sessionId) {
      const uiWorkspace = ctx.get('uiWorkspace') as { openSession?(id: string): void } | undefined
      if (uiWorkspace?.openSession !== undefined) {
        uiWorkspace.openSession(sessionId)
        return
      }
      const sessions = ctx.get('sessions') as { open?(id: string): void } | undefined
      sessions?.open?.(sessionId)
    },
  }

  const slots = ctx.slots as {
    inject(slot: string, factory: () => unknown, component?: unknown): unknown
    register(definition: unknown, component?: unknown): unknown
  }

  ctx.effect(() => {
    const dispose = slots.inject('conversation.input.overlay', () => slots.register({
      name: 'conversation.input.overlay',
      id: 'project-launcher',
      order: 6,
      inject: () => ({ hooks: { openSession: injected.openSession } }),
    }, () => h(LauncherPanel, { injected })))
    return typeof dispose === 'function' ? (dispose as () => void) : () => {}
  }, 'dsh-project-launcher: overlay chip')
}
