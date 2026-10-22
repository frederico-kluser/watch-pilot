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
LABEL="com.watchpilot.hub"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
KEY="$HOME/.ssh/watchpilot_hub_ed25519"
WRAPPER="$HOME/.local/bin/watch-pilot-hub.sh"
STATE="$HOME/.local/state/watchpilot"
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
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  LINE="command=\"$WRAPPER\",restrict,from=\"127.0.0.1,::1\" $(cat "$KEY.pub")"
  if ! grep -Fq "watchpilot-hub" "$HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$LINE" >> "$HOME/.ssh/authorized_keys"
    echo "  authorized_keys: entrada adicionada"
  else
    echo "  authorized_keys: entrada já presente"
  fi
fi

say "2/4 · wrapper em disco interno"
if [[ $DRY -eq 0 ]]; then
  mkdir -p "$(dirname "$WRAPPER")" "$STATE"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# Managed by watch-pilot/scripts/install-launchd.sh — do not edit.
set -euo pipefail
cd "$HERE/server"
export WATCHPILOT_DATA_DIR="\$HOME/.local/share/watch-pilot"
if [[ -f "\$HOME/.config/watch-pilot/env" ]]; then set -a; . "\$HOME/.config/watch-pilot/env"; set +a; fi
exec "$HERE/server/.venv/bin/python" -m uvicorn app.main:app \\
  --host 127.0.0.1 --port \${WATCHPILOT_PORT:-8765} >> "\$HOME/.local/state/watchpilot/uvicorn.log" 2>&1
WRAP
  chmod 755 "$WRAPPER"
fi

say "3/4 · LaunchDaemon"
if [[ $DRY -eq 0 ]]; then
  cat > /tmp/$LABEL.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>UserName</key><string>$(id -un)</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-F</string><string>/dev/null</string>
        <string>-i</string><string>$KEY</string>
        <string>-o</string><string>StrictHostKeyChecking=no</string>
        <string>-o</string><string>UserKnownHostsFile=/dev/null</string>
        <string>-o</string><string>BatchMode=yes</string>
        <string>-T</string>
        <string>$(id -un)@127.0.0.1</string>
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
