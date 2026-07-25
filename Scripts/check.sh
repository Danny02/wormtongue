#!/usr/bin/env bash
# Everything that can be verified without a Mac.
#
# The app target needs AppKit, Accessibility, AVFoundation, and WhisperKit, none
# of which exist on Linux — so it cannot be type-checked here. What can:
#
#   1. VoiceModeCore builds, and its test suite runs.
#   2. Every source file parses (catches syntax errors in the app target too).
#   3. swift-format lint agrees with the house style.
#   4. Structural rules that the Core/app split depends on.
#
# On a Mac, run `swift build` as well — that is the only place the app target
# gets type-checked.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
status=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; status=1; }
ok() { printf '\033[32mok\033[0m   %s\n' "$1"; }

step "VoiceModeCore builds"
if swift build 2>&1 | tail -5; then ok "build"; else fail "build"; fi

step "VoiceModeCore tests"
if swift test 2>&1 | tail -3; then ok "tests"; else fail "tests"; fi

step "Every source file parses"
parse_failures=0
while IFS= read -r file; do
	if ! out=$(swiftc -parse "$file" 2>&1); then
		fail "parse: $file"
		echo "$out" | head -5
		parse_failures=$((parse_failures + 1))
	fi
done < <(find Sources Tests -name '*.swift')
[ "$parse_failures" -eq 0 ] && ok "all files parse"

step "Formatting"
if swift-format lint --recursive --strict Sources Tests 2>&1 | head -20; then
	ok "swift-format clean"
else
	fail "swift-format lint reported findings"
fi

step "Core stays platform-free"
# If Core ever imports a macOS framework, it stops building on Linux and the
# tests stop running — which is the whole point of the split.
if banned=$(grep -rlE '^import (AppKit|SwiftUI|ApplicationServices|AVFoundation|Carbon|IOKit|WhisperKit|KeyboardShortcuts|MLX[A-Za-z]*|os)$' Sources/VoiceModeCore 2>/dev/null); then
	fail "Core imports a platform framework:"
	echo "$banned"
else
	ok "Core imports Foundation only"
fi

step "App files that use Core types import it"
missing=0
for file in $(find Sources/VoiceMode -name '*.swift'); do
	if grep -qE '\b(Config|Mode|ModeResolver|Policy|FieldContext|TailBuffer|Stopwatch|AnthropicMessages|AnthropicError)\b' "$file" \
		&& ! grep -q '^import VoiceModeCore$' "$file"; then
		fail "missing 'import VoiceModeCore': $file"
		missing=$((missing + 1))
	fi
done
[ "$missing" -eq 0 ] && ok "imports present"

step "Overlay cannot steal focus"
# makeKeyAndOrderFront on the overlay panel would move the keyboard away from the
# field we are about to type into, which breaks the entire app. Match the call,
# not the word — the source mentions it by name in a comment explaining why not.
if grep -rn 'makeKeyAndOrderFront(' Sources/VoiceMode/App/Overlay >/dev/null 2>&1; then
	fail "overlay calls makeKeyAndOrderFront; it must use orderFrontRegardless"
else
	ok "overlay uses orderFrontRegardless"
fi
if grep -q 'nonactivatingPanel' Sources/VoiceMode/App/Overlay/OverlayController.swift; then
	ok "overlay panel is non-activating"
else
	fail "overlay panel is missing .nonactivatingPanel"
fi

step "Local pass stays behind its build flag"
# An unguarded MLX import would drag the dependency into every build.
if unguarded=$(grep -rl '^import MLX' Sources/VoiceMode --include='*.swift' | while read -r f; do
	grep -q 'VOICEMODE_LOCAL_PASS' "$f" || echo "$f"
done) && [ -n "$unguarded" ]; then
	fail "MLX imported without a VOICEMODE_LOCAL_PASS guard:"
	echo "$unguarded"
else
	ok "MLX imports are guarded"
fi
if swift build 2>&1 | grep -qi 'mlx'; then
	fail "a default build resolves MLX; it must be opt-in"
else
	ok "default build does not pull MLX"
fi

step "Info.plist"
if python3 - <<'PY'
import plistlib, sys
with open("Resources/Info.plist", "rb") as handle:
    plist = plistlib.load(handle)
problems = []
if not plist.get("LSUIElement"):
    problems.append("LSUIElement must be true (menu-bar only, no focus stealing)")
if not plist.get("NSMicrophoneUsageDescription"):
    problems.append("NSMicrophoneUsageDescription missing; macOS will not prompt for the mic")
if plist.get("CFBundleExecutable") != "VoiceMode":
    problems.append("CFBundleExecutable must match the built binary name")
for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
then
	ok "plist keys present"
else
	fail "Info.plist"
fi

step "Shipped example config"
if swift test --filter "example config" 2>&1 | grep -q "passed"; then
	ok "config.example.json parses (covered by tests)"
else
	fail "config.example.json did not parse"
fi

printf '\n'
if [ $status -eq 0 ]; then
	printf '\033[32mAll Linux-side checks passed.\033[0m The app target still needs `swift build` on a Mac.\n'
else
	printf '\033[31mSome checks failed.\033[0m\n'
fi
exit $status
