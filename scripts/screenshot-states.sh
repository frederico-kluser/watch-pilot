#!/usr/bin/env bash
# Render every assistant state in the watchOS simulator and save PNGs.
#
# Used for design review (see docs/design/README.md) and as a smoke test that the
# app boots, lays out and can reach the hub from inside watchOS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${WP_SIM_DEVICE:-WatchPilot Demo}"
OUT="${1:-$HERE/docs/design/screenshots}"
DD="${WP_DERIVED_DATA:-/Volumes/Ext2TB/Caches/Xcode-DerivedData/watchpilot-sim}"
mkdir -p "$OUT"

UDID="$(xcrun simctl list devices available \
  | grep -F "$DEVICE (" \
  | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' \
  | head -1)"
if [[ -z "${UDID}" ]]; then
  echo "Erro: simulador \"$DEVICE\" não existe — Solução: xcrun simctl create \"$DEVICE\" com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-44mm com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
  exit 1
fi

APP="$DD/Build/Products/Debug-watchsimulator/WatchPilot.app"
if [[ ! -d "$APP" ]]; then
  echo "Erro: $APP não existe — Solução: xcodebuild -project apps/watch/WatchPilot.xcodeproj -scheme WatchPilot -sdk watchsimulator27.0 -configuration Debug -derivedDataPath $DD build"
  exit 1
fi

xcodebuild -project "$HERE/apps/watch/WatchPilot.xcodeproj" -scheme WatchPilot \
  -sdk watchsimulator27.0 -configuration Debug -destination "id=$UDID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath "$DD" build >/dev/null

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" me.kluser.watchpilot >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" >/dev/null

shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" me.kluser.watchpilot >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" me.kluser.watchpilot "$@" >/dev/null
  sleep "${WP_SETTLE:-4}"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "→ $OUT/$name.png"
}

shoot 01-idle      -WPDemoPhase idle
shoot 02-listening -WPDemoPhase listening
shoot 03-thinking  -WPDemoPhase waiting
shoot 04-answer    -WPDemoPhase answering
shoot 05-error     -WPDemoPhase failed
shoot 06-live-hub  -WPLiveSmoke

echo "Pronto. Estados em $OUT"
