#!/usr/bin/env bash
# Assembles VoiceMode.app around the SPM executable.
#
# An SPM executable is a bare binary, and a bare binary cannot carry an
# Info.plist — which means no LSUIElement and no microphone usage description,
# so TCC refuses to prompt. Hence this wrapper.
set -euo pipefail

CONFIG="release"
for arg in "$@"; do
	case "$arg" in
	debug | release) CONFIG="$arg" ;;
	--local-pass)
		# Pulls in MLX and enables the on-device rewrite pass. Large dependency,
		# multi-GB model downloads, and needs a Swift 6.1+ toolchain.
		export VOICEMODE_LOCAL_PASS=1
		;;
	*)
		echo "usage: $0 [debug|release] [--local-pass]" >&2
		exit 2
		;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/VoiceMode.app"

cd "$ROOT"
if [ "${VOICEMODE_LOCAL_PASS:-}" = "1" ]; then
	echo "building with the on-device rewrite pass"
fi
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VoiceMode"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceMode"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# WhisperKit ships CoreML resource bundles next to the binary; the app bundle
# needs them too.
BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Ad-hoc sign with a stable identifier so the Accessibility grant survives a
# rebuild more often than not. It is not a substitute for a Developer ID:
# expect to re-toggle the Accessibility switch after some rebuilds.
codesign --force --sign - \
	--identifier com.wormtongue.voicemode \
	--options runtime \
	--timestamp=none \
	"$APP" >/dev/null

echo "Built $APP"
echo "Run it with: open '$APP'   (or '$APP/Contents/MacOS/VoiceMode' to see logs)"
