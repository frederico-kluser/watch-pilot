#!/usr/bin/env bash
# =============================================================================
# watch-pilot-route.sh — mantém watch.kluser.me NO AR no Mac mini (boot + auto-cura)
# =============================================================================
# Corre NO macmini, dentro da sessão SSH do LaunchDaemon com.watchpilot.hub (é a
# única sessão com Full Disk Access para /Volumes/Ext2TB). Em ciclo:
#
#   1. lê a porta do router da zona de ~/.local/state/.../kluser.me/runtime.json;
#   2. pergunta ao router local por `Host: watch.kluser.me`;
#   3. se não houver rota (404) ou o router estiver morto (000), re-afirma a rota
#      com `domain.py up --name watch` (o mesmo comando de scripts/publish.sh);
#   4. a cada 5 min confirma a edge (https://watch.kluser.me/__health = 200) e,
#      em caso de falha, força a re-afirmação.
#
# Regras que respeita:
#   · pausa deliberada — se existir ~/.local/state/kluserme/heal-pause (escrito
#     por `kluserme off`/defcon), não toca em nada;
#   · nunca toca no apex, nas Page Rules, no mac.kluser.me nem no defcon4;
#   · a rota é criada com --no-gate (a app tem TOTP próprio) e --no-persist (sem
#     systemd no macOS; a persistência é este watchdog);
#   · a isenção do TOTP do zone-runner é feita uma vez por scripts/publish.sh
#     (auth.json `exempt`) e não é reescrita aqui.
#
# Log: ~/.local/state/watchpilot/route-watch.log (0600). Uma instância só (lock).
# =============================================================================
set -uo pipefail

export HOME="${HOME:-/Users/minim1}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG=en_US.UTF-8

HOST_NAME="${WATCHPILOT_HOSTNAME:-watch.kluser.me}"
PORT="${WATCHPILOT_PORT:-8765}"
ZONE="$HOME/.local/state/cloudflare-agent-skill/zones/kluser.me"
STATE="$HOME/.local/state/watchpilot"
PAUSE="$HOME/.local/state/kluserme/heal-pause"
LOG="$STATE/route-watch.log"
LOCK="$STATE/route-watch.lock"
CF_SKILL="${CLOUDFLARE_SKILL_DIR:-/Volumes/Ext2TB/Agent-Skills/cloudflare-agent-skill}"
DOMAIN="$CF_SKILL/scripts/expose-port/domain.py"
INTERVAL="${WATCHPILOT_ROUTE_INTERVAL:-30}"
EDGE_EVERY="${WATCHPILOT_EDGE_EVERY:-10}"   # ciclos entre provas da edge (10*30s = 5 min)

mkdir -p "$STATE" 2>/dev/null && chmod 700 "$STATE" 2>/dev/null
touch "$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null; }

rotate_log() {
    local size
    size=$(wc -c <"$LOG" 2>/dev/null || echo 0)
    if [ "${size:-0}" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
}

# ---- instância única --------------------------------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
    old=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 1
fi
echo $$ >"$LOCK/pid" 2>/dev/null
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ---- helpers ----------------------------------------------------------------
router_port() {
    /usr/bin/python3 - "$ZONE/runtime.json" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get("proxy_port") or "")
except Exception:
    print("")
PY
}

probe_local() {
    local port="$1"
    [ -n "$port" ] || { echo 000; return; }
    curl -s -o /dev/null -m 6 -w '%{http_code}' -H "Host: $HOST_NAME" "http://127.0.0.1:$port/" 2>/dev/null || echo 000
}

probe_edge() {
    curl -s -o /dev/null -m 12 -w '%{http_code}' "https://$HOST_NAME/__health" 2>/dev/null || echo 000
}

assert_route() {
    local reason="$1"
    log "a re-afirmar a rota ($reason)"
    CLOUDFLARE_EXPOSE_WILDCARD=0 CLOUDFLARE_EXPOSE_DOMAIN=kluser.me \
        /usr/bin/python3 "$DOMAIN" up "http://127.0.0.1:$PORT" \
        --domain kluser.me --name "${HOST_NAME%%.*}" --no-gate --no-persist \
        >>"$LOG" 2>&1
    local rc=$?
    log "domain.py up -> exit $rc"
    return $rc
}

# ---- ciclo ------------------------------------------------------------------
log "watchdog iniciado (host=$HOST_NAME porta=$PORT intervalo=${INTERVAL}s)"
ticks=0
failures=0

while :; do
    rotate_log

    if [ -e "$PAUSE" ]; then
        log "pausa ativa ($PAUSE) — não toco em nada"
        sleep "$INTERVAL"
        continue
    fi

    if [ ! -f "$DOMAIN" ]; then
        log "domain.py não encontrado em $DOMAIN — a esperar"
        sleep "$INTERVAL"
        continue
    fi

    port=$(router_port)
    code=$(probe_local "$port")

    case "$code" in
        404|000)
            assert_route "router local devolveu $code"
            failures=0
            ;;
        200|302|401|403)
            # 200 = a app responde; 401/403 = o gate TOTP da zona (não é connosco).
            failures=0
            ;;
        *)
            log "router devolveu $code — sem ação"
            ;;
    esac

    ticks=$((ticks + 1))
    if [ $((ticks % EDGE_EVERY)) -eq 0 ]; then
        edge=$(probe_edge)
        if [ "$edge" != "200" ]; then
            failures=$((failures + 1))
            log "edge devolveu $edge (falha $failures)"
            if [ "$failures" -ge 2 ]; then
                assert_route "edge em $edge"
                failures=0
            fi
        else
            if [ "$failures" -ne 0 ]; then log "edge recuperada (200)"; fi
            failures=0
        fi
    fi

    sleep "$INTERVAL"
done
