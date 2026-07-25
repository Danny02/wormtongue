# VoiceMode

Context-aware push-to-talk dictation for macOS. Menu-bar only. Personal experiment.

Hold a hotkey, speak, release. Audio is transcribed locally with Whisper, the app
reads which app and text field you're focused on plus the surrounding text, runs
the transcript through a mode-specific LLM prompt chosen by that context, and
inserts the result into the field.

```
[hotkey held] ──► AVAudioEngine tap ──► 16 kHz mono Float32
                                             │ (on release)
                        ┌────────────────────┴────────────────────┐
                        ▼                                         ▼
              WhisperKit (local)                        ContextProbe (NSWorkspace + AX)
                        │                                         │
                        └────────────────────┬────────────────────┘
                                             ▼
                                       ModeResolver
                                             ▼
                              Anthropic Messages API (Haiku)
                                             ▼
                        TextInserter (AX selected-text, else ⌘V)
```

Single process. No daemon, no local server.

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

## Config

`~/.config/voicemode/config.json`, seeded on first run. See
`config.example.json` for a fully populated one. Reload from the menu after
editing — no restart needed.

Key fields:

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

Mode resolution: bundle id → window title regex → the mode named `default`.

## Privacy boundary

Audio never leaves the machine. The rewrite pass does send data, and the
config is built so that opting in is explicit at two levels:

- Not in `llm_opt_in_bundle_ids` → raw transcript inserted, **no API call at all**.
- In `llm_opt_in_bundle_ids` but not `context_opt_in_bundle_ids` → transcript only.
- In both → transcript **plus whatever text is visible in the focused window**.

The menu bar icon becomes a filled paper plane while a request carrying screen
context is in flight (a wand when it's transcript-only), and every history row is
tagged. Both opt-in lists ship empty: out of the box this is a local dictation
app until you name an app.

Secure input (`IsSecureEventInputEnabled`) is checked before recording, and again
before inserting; a focused element with the `AXSecureTextField` subrole discards
the utterance. Password fields are never transcribed into.

## Latency

Target is under ~1.5 s from key release to inserted text. Every dictation logs a
per-stage breakdown, visible in the menu and in the history window:

```
transcribe+probe 640ms · llm 520ms · insert 21ms · total 1181ms
```

The probe and the transcription run concurrently — the probe is IPC-bound and
Whisper is compute-bound, and neither depends on the other, so overlapping them
is free.

## Layout

```
Sources/VoiceMode/
  App/            VoiceModeApp, AppState (the pipeline), MenuBarView, SetupView, HistoryView
  Audio/          AudioRecorder — AVAudioEngine tap → 16 kHz mono Float32
  Transcription/  Transcriber — WhisperKit wrapper, prewarms at launch
  Context/        AXWrapper (thin AXUIElement veneer), ContextProbe (capped traversal)
  Modes/          Config (JSON), ModeResolver (matching, prompt assembly, privacy policy)
  LLM/            AnthropicClient (POST /v1/messages), Keychain
  Insert/         TextInserter — AX selected-text, falling back to pasteboard + ⌘V
  Support/        Permissions, Hotkey, Log/Stopwatch
Resources/Info.plist
Scripts/bundle.sh
```

## Known gaps and caveats

- **Untested on hardware.** This was written on Linux with no Swift toolchain, so
  nothing here has been compiled or run. Expect to fix compile errors on the
  first build. The two most likely spots are flagged in comments:
  `Transcriber.transcribe` (WhisperKit has both an optional-returning and an
  array-returning `transcribe(audioArray:)`; the code follows the documented
  optional form) and the `KeyboardShortcuts.Recorder` label API.
- **AX traversal caps are a guess.** 800 nodes / 12 levels / 700 ms deadline.
  The brief suggested 500/8; that is likely too shallow to reach Chromium message
  content in Slack. Tuning these against real Slack, VS Code, Mail, and Safari is
  the actual work of M2 — `ProbeResult.debugSummary` is logged on every dictation
  and shown in the Setup window for exactly this.
- **Slack is the risk.** Electron apps expose a Chromium AX tree only when an
  assistive client is detected, and its shape differs from native apps. Generic
  static-text collection may need app-specific extraction logic. If Slack doesn't
  work the whole premise is weaker — test it early.
- **`insert_raw_first` is fragile.** Replacement is `raw.count` synthetic
  backspaces followed by a fresh insert. Any autocomplete, auto-pairing, or
  input-method interference between the two makes it delete the wrong thing.
  Off by default.
- **Audio tap uses an `NSLock`** on the realtime render thread. Works, but a
  lock-free ring buffer is the correct answer.
- **Cannot be sandboxed**, so no App Store. Reading another app's AX tree and
  posting synthetic events are both incompatible with the App Sandbox.
  Distribution, if ever, is Developer ID + notarization.
- Swift 6 toolchain but language mode 5 — the AX C API, `CGEvent`, and the audio
  tap callback all cross isolation boundaries in ways strict concurrency checking
  rejects. A Sendable audit is deferred, not done.

## Assumptions taken from the brief's open questions

1. **Which apps matter** — Slack, VS Code/Cursor, and a Jira/Confluence window-title
   mode are wired as examples in `config.example.json`. Both opt-in lists ship empty.
2. **Hold, not toggle** — push-to-talk on key-down/key-up.
3. **Local LLM pass via MLX** — not built. Sensitive apps skip the pass and get the
   raw transcript. The seam for it is `AppState.runPipeline`, where `policy.llmAllowed`
   currently decides between "call Anthropic" and "insert raw".
