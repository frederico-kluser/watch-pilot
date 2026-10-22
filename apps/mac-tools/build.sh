#!/usr/bin/env bash
# Build the on-device transcription CLI and install it where the hub looks for it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$HERE/../../server/bin}"
mkdir -p "$OUT_DIR"

echo "→ compiling wtx-transcribe (SpeechAnalyzer, macOS 26+)"
xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos26.0 \
  -o "$OUT_DIR/wtx-transcribe" \
  "$HERE/wtx-transcribe.swift"

chmod +x "$OUT_DIR/wtx-transcribe"
echo "→ instalado em $OUT_DIR/wtx-transcribe"
"$OUT_DIR/wtx-transcribe" --list-locales | head -c 400
echo
