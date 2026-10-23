#!/usr/bin/env bash
# Provision and build the iPhone bridge (T-800 Bridge).
#
#   scripts/install-phone.sh --pair      # write Pairing.plist from the hub's secret, then build
#   scripts/install-phone.sh --sim       # build and install into the iOS simulator
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HERE/apps/phone"
SECRET_FILE="$HOME/.config/watch-pilot/totp.secret"
PAIRING="$APP_DIR/PhoneBridge/Pairing.plist"
DD="${WP_DERIVED_DATA:-/Volumes/Ext2TB/Caches/Xcode-DerivedData/phonebridge}"
DEVICE="${WP_PHONE_DEVICE:-iPhone 17}"
MODE="build"

for arg in "$@"; do
  case "$arg" in
    --pair) MODE="pair" ;;
    --sim) MODE="sim" ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "Erro: opção desconhecida $arg — Solução: --pair ou --sim"; exit 2 ;;
  esac
done

if [[ "$MODE" == "pair" ]]; then
  echo "→ a provisionar o segredo TOTP no bundle"
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

echo "→ a gerar o projeto Xcode"
(cd "$APP_DIR" && xcodegen generate >/dev/null)

if [[ "$MODE" == "sim" ]]; then
  UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
  [[ -n "$UDID" ]] || { echo "Erro: simulador \"$DEVICE\" não existe — Solução: cria-o no Simulator."; exit 1; }
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  echo "→ a compilar para o simulador"
  xcodebuild -project "$APP_DIR/PhoneBridge.xcodeproj" -scheme PhoneBridge -sdk iphonesimulator \
    -configuration Debug -destination "id=$UDID" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -derivedDataPath "$DD" build >/dev/null
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/PhoneBridge.app"
  xcrun simctl launch "$UDID" me.kluser.watchpilot.phone
  echo "→ instalado e lançado em $DEVICE"
else
  echo "→ a compilar para o dispositivo (unsigned)"
  xcodebuild -project "$APP_DIR/PhoneBridge.xcodeproj" -scheme PhoneBridge -sdk iphoneos \
    -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath "$DD" build >/dev/null
  echo "→ build em $DD/Build/Products/Debug-iphoneos/PhoneBridge.app"
fi
