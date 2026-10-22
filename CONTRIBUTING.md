# Contributing to watch-pilot

Thanks for your interest in contributing! This document explains the workflow, conventions, and
quality bar for every change to `frederico-kluser/watch-pilot`.

Please note that this project is released with a [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you are expected to uphold it.

## Getting started

1. **Fork** the repository on GitHub and clone your fork:

   ```bash
   git clone https://github.com/<your-user>/watch-pilot.git
   cd watch-pilot
   git remote add upstream https://github.com/frederico-kluser/watch-pilot.git
   ```

2. **Bootstrap a reproducible environment** — always install from the lockfile so everyone gets the
   same dependency tree:

   ```bash
   # Node example — adapt to the project stack (pip install -e ".[dev]", go mod download, ...)
   npm ci
   npm run prepare   # installs the git hooks (husky)
   ```

   Use the toolchain versions pinned by the project (`.nvmrc`, `engines`, `go.mod`, `pyproject.toml`),
   and never commit lockfile churn produced by a different package manager.

3. **Verify the baseline** before changing anything:

   ```bash
   npm run lint && npm run format:check && npm test
   ```

## How to submit a change

- **Never push directly to `main`.** Direct pushes are blocked by repository rulesets;
  all changes land through pull requests.
- Work either on a **fork** (external contributors) or on a short-lived **ephemeral branch** in the
  main repository (maintainers), then open a pull request against `main`.
- Keep each branch focused on a single change: small, reviewable pull requests get merged faster.
- Keep your branch up to date by rebasing on `upstream/main` (do not merge
  `main` into your branch).

## Branch naming — enforced, not advisory

A repository **ruleset rejects branch names outside `<type>/<slug>`** — the push is refused
before anyone reviews it. The type set is closed:

| Pattern      | Use for                             | Example                    |
| ------------ | ----------------------------------- | -------------------------- |
| `feat/*`     | New functionality                   | `feat/rate-limiter`        |
| `fix/*`      | Bug fixes                           | `fix/null-pointer-parser`  |
| `chore/*`    | Maintenance, tooling, dependencies  | `chore/upgrade-ci`         |
| `docs/*`     | Documentation                       | `docs/api-examples`        |
| `style/*`    | Formatting, no logic change         | `style/prettier-pass`      |
| `refactor/*` | Restructuring, no behavior change   | `refactor/extract-parser`  |
| `perf/*`     | Performance                         | `perf/cache-warmup`        |
| `test/*`     | Tests                               | `test/edge-cases`          |
| `build/*`    | Build system, packaging             | `build/vite-5`             |
| `ci/*`       | CI configuration                    | `ci/runner-matrix`         |
| `revert/*`   | Reverts                             | `revert/rate-limiter`      |
| `hotfix/*`   | Emergency fixes                     | `hotfix/null-deref`        |
| `release/*`  | Past-release maintenance ONLY       | `release/1.4`              |

The slug is short, kebab-case and describes the change — never dates or people names.
Only automation branches are exempt (`dependabot/*`, `renovate/*`, `release-please--*`,
`gh-readonly-queue/*`). Long-lived branches (the default branch, `main`, `master`,
`develop`, `gh-pages`) keep their names and are protected from direct commits instead.

## Commit convention

We use [Conventional Commits](https://www.conventionalcommits.org/). The commit message becomes the
changelog entry and drives the semantic version bump, so the format is enforced.

Accepted:

```text
feat: add exponential backoff to the HTTP client
fix(parser): handle empty input without throwing
docs: document the plugin lifecycle
feat!: drop support for Node 16

feat: add retry support to the HTTP client

BREAKING CHANGE: the client constructor now requires an options object.
```

Rejected:

```text
Fixed bug                          # missing type
FEAT: add stuff                    # type must be lowercase and one of the allowed types
feat: Added stuff                  # subject must be sentence-case or lower-case
feat: add a very long subject that goes way beyond the seventy-two character limit   # header > 72 chars
feat:no space after colon          # missing space after the type separator
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
`revert`. The header must be at most **72 characters**, and the subject must be `sentence-case` or
`lower-case`.

> The `commit-msg` git hook (husky + commitlint) **rejects invalid messages at commit time**. If
> your commit was refused, fix the message with `git commit --amend` (or `git rebase -i` for older
> commits) instead of bypassing the hook.

## Local quality gates

Run these before opening a pull request — all of them must pass:

```bash
npm run lint          # static analysis
npm run format:check  # formatting
npm test              # unit/integration tests
npm run build         # compile/type-check (adapt to the stack)
```

Add or update tests for every behavioural change; a bug fix should include a regression test that
fails without the fix.

## Pull request process

1. **Title = Conventional Commit message.** The title is used as the squash-merge commit message, so
   it must follow the same convention (e.g. `feat: add exponential backoff to the HTTP client`).
2. **Describe what and why** in the body: motivation, approach, alternatives considered. Use the
   [pull request template](.github/PULL_REQUEST_TEMPLATE.md) checklist.
3. **Link related issues** with closing keywords (`Closes #123`) so issues close automatically on
   merge.
4. **Keep it green locally**: lint, format, and tests must pass before requesting review. The same
   checks run in CI as required status checks.
5. **Review requirements** (enforced by [CODEOWNERS](.github/CODEOWNERS) and repository rulesets):
   - **2 approving reviews** are required (1 for release branches).
   - Owners of the changed paths must review (code owner review is required).
   - Stale approvals are dismissed automatically when new commits are pushed.
   - All review threads must be resolved and all required status checks must pass.
6. **Squash and merge only.** Maintainers merge with the squash strategy and delete the source
   branch afterwards; the pull request title becomes the permanent commit message. Do not merge with
   merge commits or rebase-merge.

## Reporting bugs

- Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include a minimal
  reproduction, expected vs. actual behaviour, versions, and environment details.
- Feature ideas go through the
  [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
- **Security vulnerabilities must not be reported as public issues.** Follow the private process in
  [SECURITY.md](SECURITY.md) instead.

## Recognition

Every contribution counts and every contributor is credited:

- The changelog and release notes attribute merged changes to their authors.
- First-time contributors are thanked in the release announcement that includes their change.
- Significant, sustained contributions are recognised with maintainer/commit bit invitations.

Thank you for helping make watch-pilot better!
