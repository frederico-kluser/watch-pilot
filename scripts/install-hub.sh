#!/usr/bin/env bash
# Provision the Watch Pilot hub on a Mac mini: venv, transcription helper,
# secrets, LaunchDaemon and (optionally) the public subdomain.
#
#   scripts/install-hub.sh              # venv + helper + secrets + launchd
#   scripts/install-hub.sh --publish    # ... and publish watch.kluser.me
#   scripts/install-hub.sh --dry-run    # print the plan, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Erro: opção desconhecida $arg — Solução: usa --publish ou --dry-run"; exit 2 ;;
  esac
done

PORTS_RESERVED="3080 8787 8790"
PORT="${WATCHPILOT_PORT:-8765}"
for reserved in $PORTS_RESERVED; do
  if [[ "$PORT" == "$reserved" ]]; then
    echo "Erro: a porta $PORT está reservada no kluser.me — Solução: escolhe outra (WATCHPILOT_PORT=8765)."
    exit 1
  fi
done

run() {
  if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "1/6 · ambiente python"
if [[ ! -x "$HERE/server/.venv/bin/python" ]]; then
  run uv venv --python 3.13 "$HERE/server/.venv"
fi
run "$HERE/server/.venv/bin/python" -c "import fastapi" 2>/dev/null || \
  run uv pip install --python "$HERE/server/.venv/bin/python" -q \
    fastapi "uvicorn[standard]" python-multipart "httpx[http2]" pydantic

say "2/6 · transcritor on-device (SpeechAnalyzer)"
if [[ ! -x "$HERE/server/bin/wtx-transcribe" ]]; then
  run bash "$HERE/apps/mac-tools/build.sh"
else
  echo "  já existe: server/bin/wtx-transcribe"
fi

say "3/6 · segredos (~/.config/watch-pilot, 0600)"
CONF="$HOME/.config/watch-pilot"
if [[ $DRY -eq 0 ]]; then mkdir -p "$CONF"; fi
if [[ ! -f "$CONF/env" ]]; then
  if [[ $DRY -eq 0 ]]; then
    KEY="$(zsh -l -c 'printf %s "${OPENROUTER_API_KEY:-}"' 2>/dev/null || true)"
    if [[ -z "$KEY" ]]; then
      echo "  [aviso] OPENROUTER_API_KEY não encontrada no shell de login."
      echo "          escreve manualmente: echo 'OPENROUTER_API_KEY=sk-or-...' > $CONF/env && chmod 600 $CONF/env"
    fi
    umask 077
    printf 'OPENROUTER_API_KEY=%s\nWATCHPILOT_TRANSCRIBE_LOCALE=%s\n' "$KEY" "${WATCHPILOT_TRANSCRIBE_LOCALE:-pt-PT}" > "$CONF/env"
    unset KEY
  else
    echo "  [dry-run] criaria $CONF/env"
  fi
else
  echo "  já existe: $CONF/env"
fi
say "4/6 · arranque do hub (validação local)"
if [[ $DRY -eq 0 ]]; then
  "$HERE/server/.venv/bin/python" - <<PY
import sys, pathlib
sys.path.insert(0, "$HERE/server")
from app.config import settings
print(f"  porta            : {settings.port}")
print(f"  modelo           : {settings.model} (reasoning {settings.reasoning_effort})")
print(f"  transcritor      : {settings.transcribe_locale} via {settings.transcribe_backends[0]}")
print(f"  segredo TOTP     : {settings.totp_secret[:4]}… ({len(settings.totp_secret)} chars, em {pathlib.Path.home()}/.config/watch-pilot/totp.secret)")
print(f"  uri de emparelhar: {settings.totp_uri}")
PY
fi

say "5/6 · LaunchDaemon (contorna o TCC de /Volumes via SSH local)"
run bash "$HERE/scripts/install-launchd.sh" $([[ $DRY -eq 1 ]] && echo --dry-run)

say "6/6 · subdomínio público"
if [[ $PUBLISH -eq 1 ]]; then
  run bash "$HERE/scripts/publish.sh"
else
  echo "  saltado (usa --publish ou scripts/publish.sh)"
fi

say "pronto"
cat <<EOF

  health   : curl -s http://127.0.0.1:$PORT/__health
  código   : server/.venv/bin/python scripts/wp.py totp
  emparelhar: server/.venv/bin/python scripts/wp.py pair
  demo     : server/.venv/bin/python scripts/wp.py demo
  logs     : ~/.local/state/watchpilot/uvicorn.log

EOF
