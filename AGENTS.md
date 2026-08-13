# Wormtongue

## Code layout

`Sources/WormtongueCore` is platform-free: it imports Foundation only, never
AppKit, SwiftUI, ApplicationServices, AVFoundation, Carbon, IOKit, WhisperKit,
KeyboardShortcuts, or `os`. That split is the only reason the test suite runs on
Linux. Do not break it to make something compile — platform code belongs in
`Sources/Wormtongue`, the macOS app target, which is type-checked only by
`swift build` on a Mac.

## Verifying

`./Scripts/check.sh` is the gate: it builds Core, runs the tests, parses every
source file, runs `swift-format lint --strict`, and enforces the Core/app
boundary rules. Green means all of it green.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `github.com/Danny02/wormtongue`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: a `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.