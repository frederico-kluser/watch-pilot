# dsh-project-launcher

A DeepSeek Harness (DSH) plugin: **know which projects exist and where they are,
and fire new prompts in them already inside a fresh, named git worktree.**

Built from the mechanics proven by `dsh-worktree-jump` (worktree + session
transport) and `dsh-work-game` (project inventory service) — the two reference
projects this plugin was designed against.

## What it does

| Capability | How |
| --- | --- |
| **Project inventory** | scans the configured roots (`~/Projects`, `/Volumes/Ext2TB/Projects` by default) for git working trees and reports name, absolute path, branch, worktrees and last commit |
| **Prompt in a new worktree** | creates `<project>/.worktrees/<name>` (branch `<name>`), opens a **new session** whose workspace is that worktree, and **fires the prompt** into it — one call, from start to finish |

Two surfaces over one core:

- **tools** (`ctx.tools`) — `projects_list` and `projects_launch`, so an agent in
  a DSH conversation can inventory projects and open the new session itself;
- **HTTP routes** (`ctx.webServer`, behind the composition's trust fence) —
  `GET /dsh-projects/list` and `POST /dsh-projects/launch` for UI panels and
  scripts.

## Wire

```http
GET /dsh-projects/list
→ { "ok": true, "roots": [...], "projects": [ { "name", "path", "branch", "worktrees", "lastCommit" } ] }

POST /dsh-projects/launch
{ "project": "watch-pilot", "name": "feat-x", "prompt": "Arranca o trabalho…" }
→ { "ok": true, "sessionId", "worktreePath", "branch", "promptAccepted" }
```

Failures are structured (`invalid-name`, `not-git-repo`, `worktree-exists`,
`branch-exists`, `launch-failed`) and mapped to 400/404/409/502.

## Guarantees

- **Named worktrees, safe grammar**: `1–64` chars, letter/digit first, then
  letters, digits, `.`, `_`, `-`; never slashes or spaces.
- **`.worktrees/` stays invisible to `git status`** — the directory is added to
  the repository-local `.git/info/exclude`, so no tracked file is ever touched.
- **Refuses to clobber**: an existing worktree or branch name is a 409, before
  any git mutation.
- **The prompt may be refused and the session still exists** — `promptAccepted`
  reports it; the worktree and session are returned either way.
- **Never crashes the boot**: services are read defensively; a composition
  without the web/session services keeps the surface unavailable instead of
  failing.

## Install

```sh
dsh plugin --profile web add /Volumes/Ext2TB/Projects/watch-pilot/apps/dsh-project-launcher
```

The package declares `dsh.bundle.patch`, so the bundle layer inserts the plugin's
loader row itself — do not also add a manual `insert` row.

## Build & test

```sh
node node_modules/typescript/bin/tsc -p tsconfig.json   # → lib/
node --test 'lib/test/*.test.js'                        # 12 tests, no disk, no harness
```

Build-time tools are symlinked from the local DeepSeek Harness checkout
(`node_modules/typescript`, `node_modules/@types/node`); the plugin has **zero
runtime dependencies** beyond the `@deepseek-ai/cordis` peer.
