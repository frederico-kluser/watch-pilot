#!/usr/bin/env bash
# Keep the hub alive across reboot on macOS 27.
#
# Why a LaunchDaemon that opens a local SSH session instead of a plain LaunchAgent:
# on macOS 27 the TCC policy for removable volumes denies any launchd job — even as
# root — access to /Volumes/Ext2TB ("Operation not permitted"). A session coming
# from sshd-keygen-wrapper inherits Full Disk Access, so the daemon starts a
# key-restricted, localhost-only SSH session whose forced command runs the hub.
# This is the same pattern the machine already uses for its DSH web service.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This script needs root to write /Library/LaunchDaemons, but the service must run as
# the *login* user: `id -un` under sudo is root, which has no key and no FDA.
TARGET_USER="${SUDO_USER:-$(id -un)}"
if [[ "$TARGET_USER" == "root" ]]; then
  echo "Erro: sudo sem SUDO_USER — Solução: corre 'sudo bash scripts/install-launchd.sh' como utilizador normal."
  exit 1
fi
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -d "$TARGET_HOME" ]] || TARGET_HOME="/Users/$TARGET_USER"

LABEL="com.watchpilot.hub"
PORT="${WATCHPILOT_PORT:-8765}"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
KEY="$TARGET_HOME/.ssh/watchpilot_hub_ed25519"
WRAPPER="$TARGET_HOME/.local/bin/watch-pilot-hub.sh"
STATE="$TARGET_HOME/.local/state/watchpilot"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

run() { if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "1/4 · chave SSH dedicada (só localhost, só o wrapper)"
if [[ ! -f "$KEY" ]]; then
  run ssh-keygen -q -t ed25519 -N "" -C "watchpilot-hub" -f "$KEY"
else
  echo "  já existe: $KEY"
fi
if [[ $DRY -eq 0 ]]; then
  mkdir -p "$TARGET_HOME/.ssh"
  touch "$TARGET_HOME/.ssh/authorized_keys"
  chmod 600 "$TARGET_HOME/.ssh/authorized_keys"
  LINE="command=\"$WRAPPER\",restrict,from=\"127.0.0.1,::1\" $(cat "$KEY.pub")"
  if ! grep -Fq "watchpilot-hub" "$TARGET_HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$LINE" >> "$TARGET_HOME/.ssh/authorized_keys"
    echo "  authorized_keys: entrada adicionada"
  else
    echo "  authorized_keys: entrada já presente"
  fi
fi

say "2/4 · wrapper + watchdog de rota em disco interno"
if [[ $DRY -eq 0 ]]; then
  mkdir -p "$(dirname "$WRAPPER")" "$STATE"
  install -m 755 "$HERE/scripts/watch-pilot-route.sh" "$(dirname "$WRAPPER")/watch-pilot-route.sh"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# Managed by watch-pilot/scripts/install-launchd.sh — do not edit.
set -euo pipefail
cd "$HERE/server"
export WATCHPILOT_DATA_DIR="\$HOME/.local/share/watch-pilot"
if [[ -f "\$HOME/.config/watch-pilot/env" ]]; then set -a; . "\$HOME/.config/watch-pilot/env"; set +a; fi

# 1) watch.kluser.me must come back on its own after a reboot: the route watchdog
#    re-asserts the Cloudflare route (the hub alone cannot do it). Detached with its
#    own lock so a restart of this session never leaves two watchers fighting.
if [[ -x "\$HOME/.local/bin/watch-pilot-route.sh" ]]; then
  nohup setsid "\$HOME/.local/bin/watch-pilot-route.sh" >/dev/null 2>&1 &
fi

# 2) the hub runs as a child (not exec) so that when sshd hangs up this session we
#    can take uvicorn down with it. With exec, a bootout/reboot leaves an orphan
#    holding :8765 and the next start dies with "address already in use".
"$HERE/server/.venv/bin/python" -m uvicorn app.main:app \\
  --host 127.0.0.1 --port \${WATCHPILOT_PORT:-8765} >> "\$HOME/.local/state/watchpilot/uvicorn.log" 2>&1 &
UV=\$!
trap 'kill -TERM "\$UV" 2>/dev/null' TERM INT HUP EXIT
wait "\$UV"
WRAP
  chmod 755 "$WRAPPER"
  # Everything the service touches must belong to the login user: this script runs as
  # root, so any file it creates is root-owned by default and the wrapper then fails
  # with "Permission denied" when it tries to append to its log.
  chown "$TARGET_USER" "$WRAPPER" "$KEY" "$KEY.pub" 2>/dev/null || true
  chmod 600 "$KEY"
  chown -R "$TARGET_USER" "$STATE" 2>/dev/null || true
  chmod 755 "$STATE"
fi

say "3/4 · LaunchDaemon"
if [[ $DRY -eq 0 ]]; then
  cat > /tmp/$LABEL.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>UserName</key><string>$TARGET_USER</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-F</string><string>/dev/null</string>
        <string>-i</string><string>$KEY</string>
        <string>-o</string><string>StrictHostKeyChecking=no</string>
        <string>-o</string><string>UserKnownHostsFile=/dev/null</string>
        <string>-o</string><string>BatchMode=yes</string>
        <string>-T</string>
        <string>$TARGET_USER@127.0.0.1</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>20</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$STATE/launchd.log</string>
    <key>StandardErrorPath</key><string>$STATE/launchd.log</string>
</dict>
</plist>
PLIST
  plutil -lint /tmp/$LABEL.plist
  sudo install -o root -g wheel -m 644 /tmp/$LABEL.plist "$PLIST"
  rm -f /tmp/$LABEL.plist
fi

say "4/4 · carregar"
if [[ $DRY -eq 0 ]]; then
  # A previous run that was not supervised (or an older exec-based wrapper) can leave
  # an orphan on the port; the new job would then boot-loop with EADDRINUSE.
  stale=$(/usr/sbin/lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "$stale" ]]; then
    echo "  a libertar a porta $PORT de processos não supervisionados: $stale"
    sudo -n kill $stale 2>/dev/null || true
    sleep 2
  fi
fi
run sudo launchctl bootout system "$PLIST" 2>/dev/null || true
run sudo launchctl bootstrap system "$PLIST"
run sudo launchctl enable "system/$LABEL"

if [[ $DRY -eq 0 ]]; then
  sleep 6
  if curl -sf -m 5 "http://127.0.0.1:${WATCHPILOT_PORT:-8765}/__health" >/dev/null; then
    echo "  hub a responder no daemon ✓"
  else
    echo "  hub ainda não responde — vê $STATE/launchd.log e $STATE/uvicorn.log"
  fi
fi
