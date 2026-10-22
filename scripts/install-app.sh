#!/usr/bin/env bash
# Provision and build the watchOS app.
#
#   scripts/install-app.sh --pair      # write Pairing.plist from the hub's secret, then build
#   scripts/install-app.sh --build     # just build for device (unsigned)
#   scripts/install-app.sh --sim       # build and install into the watchOS simulator
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HERE/apps/watch"
SECRET_FILE="$HOME/.config/watch-pilot/totp.secret"
PAIRING="$APP_DIR/WatchPilot/Pairing.plist"
MODE="build"
DEVICE="${WP_SIM_DEVICE:-WatchPilot Demo}"
DD="${WP_DERIVED_DATA:-/Volumes/Ext2TB/Caches/Xcode-DerivedData/watchpilot-sim}"

for arg in "$@"; do
  case "$arg" in
    --pair) MODE="pair" ;;
    --build) MODE="build" ;;
    --sim) MODE="sim" ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Erro: opção desconhecida $arg — Solução: --pair, --build ou --sim"; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [[ "$MODE" == "pair" ]]; then
  say "a provisionar o segredo TOTP no bundle"
  if [[ ! -f "$SECRET_FILE" ]]; then
    echo "Erro: $SECRET_FILE não existe — Solução: arranca o hub uma vez (scripts/run-hub.sh)."
    exit 1
  fi
  umask 077
  cat > "$PAIRING" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>totp_secret</key>
	<string>$(cat "$SECRET_FILE")</string>
</dict>
</plist>
PLIST
  chmod 600 "$PAIRING"
  echo "  escrito $PAIRING (0600, git-ignored)"
fi

say "a gerar o projeto Xcode"
if ! command -v xcodegen >/dev/null; then
  echo "Erro: xcodegen em falta — Solução: brew install xcodegen"
  exit 3
fi
(cd "$APP_DIR" && xcodegen generate --spec project.yml >/dev/null)
echo "  apps/watch/WatchPilot.xcodeproj"

if [[ "$MODE" == "sim" ]]; then
  say "a construir para o simulador"
  UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" \
    | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
  if [[ -z "$UDID" ]]; then
    echo "Erro: simulador \"$DEVICE\" não existe — Solução: xcrun simctl create \"$DEVICE\" com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-44mm com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
    exit 1
  fi
  xcodebuild -project "$APP_DIR/WatchPilot.xcodeproj" -scheme WatchPilot \
    -sdk watchsimulator27.0 -configuration Debug -destination "id=$UDID" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath "$DD" build \
    | grep -E "BUILD (SUCCEEDED|FAILED)"
  xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-watchsimulator/WatchPilot.app"
  xcrun simctl launch "$UDID" me.kluser.watchpilot >/dev/null
  echo "  lançado no simulador $UDID"
  exit 0
fi

say "a construir para o relógio (sem assinatura)"
xcodebuild -project "$APP_DIR/WatchPilot.xcodeproj" -scheme WatchPilot \
  -sdk watchos27.0 -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath "$DD/device" build | grep -E "BUILD (SUCCEEDED|FAILED)"
echo
echo "Para instalar no Apple Watch SE: abre apps/watch/WatchPilot.xcodeproj,"
echo "escolhe a tua Personal Team em Signing & Capabilities e corre para o relógio."
echo "(ver docs/SETUP.md §3)"
