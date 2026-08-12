#!/usr/bin/env bash
# Assembles Wormtongue.app around the SPM executable.
#
# An SPM executable is a bare binary, and a bare binary cannot carry an
# Info.plist — which means no LSUIElement and no microphone usage description,
# so TCC refuses to prompt. Hence this wrapper.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Wormtongue.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Wormtongue"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wormtongue"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# WhisperKit ships CoreML resource bundles next to the binary; the app bundle
# needs them too.
BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# TCC ties permission grants to the code signature. A stable signing identity
# (self-signed cert named "VoiceMode Dev", or $CODESIGN_IDENTITY) keeps the
# microphone/Accessibility grants across rebuilds; ad-hoc (-) loses them.
#
# The entitlements are not optional: --options runtime without
# com.apple.security.device.audio-input means the microphone request is denied
# before it reaches the user, with no prompt and no error.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "VoiceMode Dev"; then
	IDENTITY="VoiceMode Dev"
fi
if [[ -z "$IDENTITY" ]]; then
	IDENTITY="-"
	echo "warning: no signing identity — permissions reset every rebuild." >&2
	echo "warning: create a self-signed 'Code Signing' cert named 'VoiceMode Dev' in Keychain Access." >&2
fi
codesign --force --sign "$IDENTITY" \
	--identifier com.wormtongue.wormtongue \
	--options runtime \
	--entitlements "$ROOT/Resources/Wormtongue.entitlements" \
	--timestamp=none \
	"$APP" >/dev/null

echo "Built $APP"
echo "Run it with: open '$APP'   (or '$APP/Contents/MacOS/Wormtongue' to see logs)"
