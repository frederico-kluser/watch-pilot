#!/usr/bin/env bash
# Start the Watch Pilot hub in the foreground.
#
# OPENROUTER_API_KEY is read from ~/.config/watch-pilot/env (0600) written by
# scripts/install-hub.sh, falling back to the login shell environment.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${WATCHPILOT_ENV_FILE:-$HOME/.config/watch-pilot/env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
if [[ -z "${OPENROUTER_API_KEY:-}" && -f "$HOME/.zshenv" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$HOME/.zshenv" >/dev/null 2>&1 || true
  set +a
fi

cd "$HERE/server"
exec .venv/bin/uvicorn app.main:app \
  --host "${WATCHPILOT_HOST:-127.0.0.1}" \
  --port "${WATCHPILOT_PORT:-8765}" \
  --log-level "${WATCHPILOT_LOG_LEVEL:-info}"
