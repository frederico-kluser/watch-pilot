#!/usr/bin/env bash
# Validate the iPhone bridge end to end, unattended.
#
#   scripts/phone-e2e.sh        # build + run a full voice turn and check every claim
#
# It emulates the microphone with generated speech (OpenRouter), runs a complete
# turn INSIDE the app (capture → hub → spoken reply → Apple Intelligence briefing)
# and then checks the route probes and the notification endpoint, all from the
# app's own logs. Exit 0 = every check green.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${WP_DERIVED_DATA:-/Volumes/Ext2TB/Caches/XCode-DerivedData/phonebridge}"
DD="${DD/XCode/Xcode}"
DEVICE="${WP_PHONE_DEVICE:-iPhone 17}"
UDID="$(xcrun simctl list devices available | grep -F "$DEVICE (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
[[ -n "$UDID" ]] || { echo "Erro: simulador \"$DEVICE\" não existe — Solução: cria-o no Simulator."; exit 1; }

PASS=0; FAIL=0
check() { local name="$1"; local ok="$2"; local detail="${3:-}"
  if [[ "$ok" == "1" ]]; then PASS=$((PASS+1)); echo "  [OK] $name${detail:+ — $detail}"
  else FAIL=$((FAIL+1)); echo "  [FALHOU] $name${detail:+ — $detail}"; fi }

echo "══ phone-e2e · T-800 Bridge ═══════════════════════════════"

echo "1/4 · microfone emulado via OpenRouter"
AUDIO=/tmp/phone-e2e-turn.m4a
python3 - "$AUDIO" <<'PY' || exit 1
import sys; sys.path.insert(0, "scripts")
import wp
from pathlib import Path
wp.synthesise("Watch Pilot, que horas são em Macau?", Path(sys.argv[1]), source="openrouter")
PY
SIZE=$(stat -f%z "$AUDIO" 2>/dev/null || echo 0)
check "áudio do microfone gerado" "$([[ $SIZE -gt 1000 ]] && echo 1 || echo 0)" "$SIZE bytes"

echo "2/4 · compilar e lançar a ponte"
(cd "$HERE/apps/phone" && xcodegen generate >/dev/null && xcodebuild -project PhoneBridge.xcodeproj \
  -scheme PhoneBridge -sdk iphonesimulator -configuration Debug -destination "id=$UDID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath "$DD" build >/dev/null 2>&1)
check "build para iOS" "$([[ -d "$DD/Build/Products/Debug-iphonesimulator/PhoneBridge.app" ]] && echo 1 || echo 0)"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/PhoneBridge.app" >/dev/null 2>&1
xcrun simctl terminate "$UDID" me.kluser.watchpilot.phone >/dev/null 2>&1
xcrun simctl launch "$UDID" me.kluser.watchpilot.phone -WPTurnFile "$AUDIO" -WPNoNotifications >/dev/null 2>&1

echo "3/4 · turno completo dentro da app (gravar → Mac mini → fala → briefing)"
sleep 45
LOG="$(xcrun simctl spawn "$UDID" log show --last 3m --predicate 'eventMessage CONTAINS "TURN-" OR eventMessage CONTAINS "PROBE" OR eventMessage CONTAINS "INBOX"' 2>/dev/null)"
check "turno iniciado (áudio enviado)" "$(grep -c 'TURN-START' <<<"$LOG" | awk '{print ($1>0)?1:0}')"
DONE_LINE="$(grep 'TURN-DONE' <<<"$LOG" | tail -1)"
check "turno concluído pelo hub" "$(grep -q 'fase=finished' <<<"$DONE_LINE" && echo 1 || echo 0)" "$(grep -o 'transcrição=[^r]*' <<<"$DONE_LINE" | head -c 80)"
check "transcrição não vazia" "$(grep -q 'transcrição=Watch Pilot' <<<"$DONE_LINE" && echo 1 || echo 0)"
check "resposta falada entregue" "$(grep -q 'resposta=.' <<<"$DONE_LINE" && echo 1 || echo 0)"
check "briefing Apple Intelligence gerado" "$(grep -c 'TURN-BRIEFING' <<<"$LOG" | awk '{print ($1>0)?1:0}')"

echo "4/4 · rotas públicas e endpoint de notificações"
check "watch.kluser.me online (sonda da app)" "$(grep -q 'PROBE: watch.kluser.me online' <<<"$LOG" && echo 1 || echo 0)" "$(grep -o 'PROBE: watch.kluser.me online ([0-9]* ms)' <<<"$LOG" | tail -1 | grep -o '[0-9]* ms')"
check "mac.kluser.me online (sonda da app)" "$(grep -q 'PROBE: mac.kluser.me online' <<<"$LOG" && echo 1 || echo 0)" "$(grep -o 'PROBE: mac.kluser.me online ([0-9]* ms)' <<<"$LOG" | tail -1 | grep -o '[0-9]* ms')"
check "notificações apanhadas do endpoint" "$(grep -c 'INBOX: [0-9]* itens' <<<"$LOG" | awk '{print ($1>0)?1:0}')" "$(grep -o 'INBOX: [0-9]* itens do endpoint ([0-9]* novos)' <<<"$LOG" | tail -1)"

echo "════════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then echo "RESULTADO: $PASS/$PASS verificações — ponte validada ponta-a-ponta"; exit 0
else echo "RESULTADO: $PASS/$((PASS+FAIL)) verificações — $FAIL falha(s)"; exit 1; fi
