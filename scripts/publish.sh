#!/usr/bin/env bash
# Publish the hub on a kluser.me subdomain through the Cloudflare tunnel.
#
# Two things make this work for a machine client (the watch):
#   1. `--no-gate`  : no ?key= cookie gate — the app has its own TOTP auth;
#   2. the host must be in the zone-runner's TOTP `exempt` list, otherwise every
#      non-GET request is answered 401 by the edge router before reaching the hub.
set -euo pipefail

HOST="${WATCHPILOT_HOSTNAME:-watch.kluser.me}"
NAME="${HOST%%.*}"
PORT="${WATCHPILOT_PORT:-8765}"
CF_SKILL="${CLOUDFLARE_SKILL_DIR:-$HOME/Agent-Skills/cloudflare-agent-skill}"
ZONE_DIR="$HOME/.local/state/cloudflare-agent-skill/zones/kluser.me"

if [[ ! -f "$CF_SKILL/scripts/expose-port/domain.py" ]]; then
  echo "Erro: domain.py não encontrado em $CF_SKILL — Solução: define CLOUDFLARE_SKILL_DIR."
  exit 1
fi

echo "→ 1/2 · isentar $HOST do gate TOTP do zone-runner"
python3 "$(dirname "$0")/exempt-host.py" "$ZONE_DIR" "$HOST"

echo "→ 2/2 · publicar $HOST → 127.0.0.1:$PORT"
CLOUDFLARE_EXPOSE_WILDCARD=0 CLOUDFLARE_EXPOSE_DOMAIN=kluser.me \
  /usr/bin/python3 "$CF_SKILL/scripts/expose-port/domain.py" \
  up "http://127.0.0.1:$PORT" --domain kluser.me --name "$NAME" --no-gate --no-persist

echo
echo "→ a verificar pela edge (pode levar até 30 s a propagar)"
for attempt in 1 2 3 4 5 6; do
  status="$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$HOST/__health" || true)"
  echo "  tentativa $attempt: __health=$status"
  [[ "$status" == "200" ]] && break
  sleep 5
done
echo
echo "  URL      : https://$HOST/"
echo "  nota     : a rota é efémera (cai no reboot) e o watchdog do mac.kluser.me"
echo "             pode removê-la num próximo 'up' — re-corre este script se a edge devolver 404."
