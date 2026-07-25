# VoiceMode

Context-aware push-to-talk dictation for macOS. Menu-bar only. Personal experiment.

Hold a hotkey, speak, release. Audio is transcribed locally with Whisper, the app
reads which app and text field you're focused on plus the surrounding text, runs
the transcript through a mode-specific LLM prompt chosen by that context, and
inserts the result into the field.

```
[hotkey down] ──► AVAudioEngine tap ──► 16 kHz mono Float32
       │                                      │ (on release)
       ├─► ContextProbe (AX tree)             ▼
       └─► TLS warm-up            WhisperKit (local, on-device)
                    │                         │
                    └────────────┬────────────┘
                                 ▼
                           ModeResolver
                                 ▼
                    Anthropic Messages API (Haiku)
                                 ▼
              TextInserter (AX selected-text, else ⌘V)
```

The AX probe and the TLS handshake start on key-**down**, so by the time you stop
talking they're already done. Single process, no daemon, no local server.

## Build

Requires macOS 14+, Apple Silicon, and a Swift 6 toolchain (Xcode 16+).

```sh
./Scripts/bundle.sh          # release build → build/VoiceMode.app
./Scripts/bundle.sh debug    # debug build
open build/VoiceMode.app
```

Run the binary directly to watch the pipeline log:

```sh
build/VoiceMode.app/Contents/MacOS/VoiceMode
```

`swift build && swift run` also works, but the bare executable has no
`Info.plist`, so `LSUIElement` and the microphone usage string are missing and
macOS will not prompt for mic access. Use the bundle for anything real.

## Checks

The package is split so most of the logic can be verified without a Mac:

| Target | Contents | Verifiable on Linux |
|---|---|---|
| `VoiceModeCore` | Config decoding, mode resolution, privacy policy, prompt assembly, context tail buffer, Anthropic request/response coding | **Yes** — builds and has 53 tests |
| `VoiceMode` | AppKit, Accessibility, AVFoundation, WhisperKit, SwiftUI | No — needs the macOS SDK |

`Package.swift` declares the macOS target and its dependencies inside
`#if os(macOS)`, so on Linux the graph collapses to Core plus tests with no
external dependencies to resolve.

```sh
./Scripts/check.sh
```

runs everything that doesn't need a Mac:

1. `swift build` and `swift test` for Core.
2. `swiftc -parse` on **every** file, app target included — catches syntax
   errors in the code that can't be type-checked.
3. `swift-format lint --strict` against `.swift-format`.
4. Structural rules the split depends on: Core imports nothing but Foundation,
   app files that use Core types import it, the overlay panel never calls
   `makeKeyAndOrderFront`, and `Info.plist` has the keys without which the app
   silently misbehaves.

On a Mac, `swift build` is still the only thing that type-checks the app target.

## First run

The menu bar item shows a warning triangle until Accessibility is granted. Open
**Setup & Permissions…** from the menu; it shows live status for each permission
and deep-links into the right System Settings pane.

| Permission | Needed for |
|---|---|
| Accessibility | Reading the focused app's AX tree **and** posting the paste keystroke. Must be toggled by hand in System Settings. |
| Microphone | Recording. Prompted on first request. |
| Input Monitoring | Global hotkey delivery, depending on the app's state. |

Then set the hotkey (defaults to ⌘⌥D, hold to talk) and paste an Anthropic API
key — it goes into the Keychain, not the config file. `ANTHROPIC_API_KEY` is
honoured as a fallback so `swift run` works before you've stored one.

**Ad-hoc signing caveat:** `bundle.sh` signs with a stable identifier
(`com.wormtongue.voicemode`) so the Accessibility grant usually survives a
rebuild, but not always. If dictation silently stops working after a rebuild,
remove VoiceMode from System Settings → Privacy & Security → Accessibility and
re-add it.

## Using it

- **Hold** the hotkey, talk, release.
- A floating panel appears near the bottom of the screen: a live level meter
  while recording (so you can see the mic is hearing you), then the stage it's
  on, then the inserted text. It's a non-activating panel that ignores mouse
  events — it cannot take focus from the field you're dictating into.
- **Press the hotkey again while it's working** to cancel. Nothing is inserted.
- Short system sounds mark start, insert, and failure. Turn them off with
  `"sound_feedback": false`; turn the panel off with `"show_overlay": false`.

## Config

`~/.config/voicemode/config.json`, seeded on first run. See
`config.example.json` for a fully populated one. Reload from the menu after
editing — no restart needed. Every key is optional; a config missing half its
fields loads with defaults for the rest rather than refusing to start.

| Field | Meaning |
|---|---|
| `whisper_model` | WhisperKit model. `base` downloads in seconds and is the right choice while wiring things up; switch to `large-v3-v20240930_turbo` once the pipeline works. |
| `model` | Rewrite model. Per-mode override via `modes[].model`. |
| `dictionary` | Proper nouns, ticket prefixes, jargon. Injected into every system prompt. |
| `llm_opt_in_bundle_ids` | **Apps opt in.** Anything not listed gets the raw transcript inserted and nothing leaves the machine. |
| `context_opt_in_bundle_ids` | Narrower: only these apps have their on-screen text sent to the API. |
| `denied_bundle_ids` | Hard deny. Not probed, not sent, raw transcript only. Wins over everything. |
| `context_char_cap` | Ceiling on surrounding-text characters. The *tail* is kept — in a chat window the recent messages are last. |
| `insert_raw_first` | Insert the raw transcript immediately, replace when the LLM returns. Off by default; see caveats. |
| `show_overlay`, `sound_feedback` | UI feedback toggles. |

Mode resolution: bundle id → window title regex → the mode named `default`.
A regex that doesn't compile is reported in the menu and the Setup window rather
than silently never matching.

## Privacy boundary

Audio never leaves the machine. The rewrite pass does send data, and the
config is built so that opting in is explicit at two levels:

- Not in `llm_opt_in_bundle_ids` → raw transcript inserted, **no API call at all**.
- In `llm_opt_in_bundle_ids` but not `context_opt_in_bundle_ids` → transcript only.
- In both → transcript **plus whatever text is visible in the focused window**.

The overlay says "sending screen context" in words while such a request is in
flight, the menu bar icon becomes a filled paper plane, and every history row is
tagged. Both opt-in lists ship empty: out of the box this is a local dictation
app until you name an app.

Secure input (`IsSecureEventInputEnabled`) is checked before recording and again
before inserting; a focused element with the `AXSecureTextField` subrole discards
the utterance. Password fields are never transcribed into.

On-screen text is treated as untrusted input: angle brackets in it are
neutralised so a Slack message containing `</visible_context>` can't close our
own tag and read as instructions. The transcript itself is passed through
verbatim — mangling it would corrupt dictated code.

## Latency

Target is under ~1.5 s from key release to inserted text. Every dictation logs a
per-stage breakdown, visible in the menu and the history window:

```
transcribe 610ms · probe 240ms · llm 480ms · insert 18ms · total 1114ms
```

What was done to get there:

| | |
|---|---|
| **Probe on key-down** | The AX traversal is 100–700 ms of pure IPC. Running it while you're still talking takes it off the post-release path entirely — focus can't change while you're holding the key. `probe` is reported for visibility but doesn't add to the total. |
| **TLS warm-up on key-down** | A free `GET /v1/models` opens the connection so the rewrite doesn't pay DNS + TCP + TLS + HTTP/2 setup (100–300 ms), throttled to once per 50 s. Only fires for apps opted in to the LLM pass. |
| **Batched AX reads** | `AXUIElementCopyMultipleAttributeValues` fetches role and value in one round trip instead of two. Halves IPC across a traversal that visits hundreds of nodes. |
| **Pruned traversal** | Menu bars, toolbars, scroll bars, images, and sliders can't contain conversation text, so their subtrees are skipped and the node budget goes to content. |
| **Bounded context collection** | `TailBuffer` keeps only the last `context_char_cap` characters as it walks, so a busy Slack channel never materialises its whole scrollback to then throw most of it away. |
| **Prepared mode resolution** | `ModeResolver` compiles the window-title regexes and builds set-based bundle-id lookups once per config load, not once per utterance. |
| **Allocation-free audio tap** | The destination PCM buffer is created once and reused, the sample store is preallocated, and the render-thread critical section is a `memcpy` under an unfair lock. |
| **Metering by polling** | The overlay's level meter polls the recorder at 20 Hz instead of publishing from the audio thread, so SwiftUI invalidation never happens on a realtime thread. |
| **Whisper prewarm** | The model loads at launch, so the first dictation doesn't pay for the download. |

## Layout

```
Sources/VoiceModeCore/       Foundation only, tested
  Config, ModeResolver (matching + policy + prompts), FieldContext,
  TailBuffer, Stopwatch, AnthropicMessages (wire types + parsing)
Sources/VoiceMode/
  App/            VoiceModeApp, AppState (the pipeline), MenuBarView,
                  SetupView, HistoryView, Overlay/
  Audio/          AudioRecorder — AVAudioEngine tap → 16 kHz mono Float32
  Transcription/  Transcriber — WhisperKit wrapper, prewarms at launch
  Context/        AXWrapper (batched AXUIElement reads), ContextProbe
  LLM/            AnthropicClient (transport, warm-up, retry), Keychain
  Insert/         TextInserter — AX selected-text, falling back to ⌘V
  Support/        Permissions, Hotkey, ConfigStore, Feedback, Log
Tests/VoiceModeCoreTests/    53 tests
Resources/Info.plist
Scripts/bundle.sh, Scripts/check.sh
```

## Known gaps and caveats

- **The app target has never been compiled.** It was written on Linux, where the
  macOS SDK doesn't exist. Core is built and tested, every file parses, and the
  structural checks pass — but expect to fix type errors in the app target on the
  first real build. The two likeliest spots are flagged in comments:
  `Transcriber.transcribe` (WhisperKit has both an optional-returning and an
  array-returning `transcribe(audioArray:)`; the code follows the documented
  optional form) and the `KeyboardShortcuts.Recorder` label API.
- **AX traversal caps are a guess.** 800 nodes / 12 levels / 700 ms. The brief
  suggested 500/8; that is likely too shallow to reach Chromium message content
  in Slack. Tuning these against real Slack, VS Code, Mail, and Safari is the
  actual work of M2 — `FieldContext.debugSummary` is logged on every dictation
  and shown in the Setup window, including node count and elapsed time.
- **Slack is the risk.** Electron apps expose a Chromium AX tree only when an
  assistive client is detected, and its shape differs from native apps. Generic
  static-text collection may need app-specific extraction logic. If Slack doesn't
  work the whole premise is weaker — test it early.
- **`insert_raw_first` is fragile.** Replacement is `raw.count` synthetic
  backspaces followed by a fresh insert. Any autocomplete, auto-pairing, or
  input-method interference between the two makes it delete the wrong thing. It
  also leaves the pasteboard un-restored, because the second paste invalidates
  the first restore's change-count guard. Off by default.
- **The audio tap takes a lock.** An unfair lock around a `memcpy` is far better
  than the `NSLock` + `Array.append` it replaced, but a lock-free ring buffer is
  the correct answer for a realtime thread.
- **Cannot be sandboxed**, so no App Store. Reading another app's AX tree and
  posting synthetic events are both incompatible with the App Sandbox.
  Distribution, if ever, is Developer ID + notarization.
- **Language mode 5 in the app target.** The AX C API, `CGEvent`, and the audio
  tap callback all cross isolation boundaries in ways strict concurrency checking
  rejects. Core is checked strictly; a Sendable audit of the app target is
  deferred, not done.

## Assumptions taken from the brief's open questions

1. **Which apps matter** — Slack, VS Code/Cursor, and a Jira/Confluence window-title
   mode are wired as examples in `config.example.json`. Both opt-in lists ship empty.
2. **Hold, not toggle** — push-to-talk on key-down/key-up.
3. **Local LLM pass via MLX** — not built. Sensitive apps skip the pass and get the
   raw transcript. The seam for it is `AppState.runPipeline`, where `policy.llmAllowed`
   currently decides between "call Anthropic" and "insert raw".
