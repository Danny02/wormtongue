# Wormtongue

Push-to-talk dictation for macOS. Hold a hotkey, speak, and your words appear in the field you're focused on — a chat message, an email, a code editor, a ticket comment. It lives quietly in the menu bar until you hold the key.

Wormtongue is not just speech-to-text. It reads which app you're in and the text around your cursor, then uses that context to format what you say — expand a ticket reference, match the field's tone, or rewrite a draft you ask it to change.

Your audio is transcribed on your own Mac. It never leaves your machine.

## Requirements

- macOS 14 (Sonoma) or later
- An Apple Silicon Mac
- An Anthropic API key

## Install

1. Download the latest `Wormtongue-macOS-*.zip` from the [Releases](https://github.com/Danny02/wormtongue/releases) page.
2. Unzip it and drag `Wormtongue.app` into your Applications folder.
3. The app is not notarized, so the first launch shows an "unidentified developer" warning. Right-click `Wormtongue.app` → **Open**, then click **Open** in the dialog. You only do this once.
4. Complete the setup below.

## First launch

Wormtongue appears in the menu bar as a small icon. Open **Setup & Permissions…** from the menu to get everything ready.

It needs three macOS permissions:

| Permission | Why | How to grant |
|---|---|---|
| **Accessibility** | Reading which field you're focused on and pasting text | Toggle it on by hand in System Settings → Privacy & Security → Accessibility. The app can't turn this on for you. |
| **Microphone** | Recording your voice | Wormtongue prompts for this itself the first time you hold the hotkey. |
| **Input Monitoring** | The global hotkey reaching the app | Grant it if macOS asks. |

Then, in the Setup window:

1. Set your **hotkey** — the default is **⌘⌥D**, held while you talk.
2. Paste your **Anthropic API key**. It is stored in your Mac's Keychain, never in a file.

## Using it

- **Hold** the hotkey, speak, release. Wormtongue transcribes locally and inserts the result at your cursor.
- Prefer **toggle** mode? Set `"hotkey_mode": "toggle"` in config: press once to start recording, press again to stop.
- Press the hotkey again while it's working to **cancel** — nothing is inserted.
- If Wormtongue rewrote an existing draft, the menu bar menu offers **Revert last edit** to undo it.
- A small panel near the bottom of the screen shows a level meter while you speak, then the inserted text. It never takes focus from the field you're typing into.
- Short system sounds mark start, insert, and failure. Turn the panel or the sounds off in config if you'd rather be silent.

## What leaves your Mac

Audio never leaves the machine. The rewrite pass does send data, and Wormtongue only reads more of your screen when you say it can:

- By default it sends only the **transcript** of what you just said for rewriting.
- Apps in `denied_bundle_ids` get the raw transcript inserted — **no API call at all**.
- It reads the focused field's own text only for apps you name in `edit_opt_in_bundle_ids` — that's what makes editing an existing draft possible.
- It reads the surrounding on-screen text only for apps you name in `context_opt_in_bundle_ids`.
- Both opt-in lists ship **empty**. Out of the box this is a local dictation app until you name an app.
- Password fields are never transcribed.

The panel says "sending screen context" in plain words whenever such a request is in flight.

## Configuration

Settings live in `~/.config/wormtongue/config.json`, created on first run. Edit it and choose **Reload Config** from the menu — no restart needed. Every key is optional. A full example is in `config.example.json` in the repository.

| Key | What it does |
|---|---|
| `whisper_model` | Transcription model. `base` is fast and downloads quickly — good to start. Switch to `large-v3-v20240930_turbo` for better accuracy on hard audio. |
| `whisper_language` | Whisper language code (`"de"`, `"en"`, …). Leave it out to detect the language per utterance — right if you speak more than one. |
| `model` | The rewrite model, e.g. `claude-haiku-4-5-20251001`. Per-app override via `modes[].model`. |
| `dictionary` | Words it should always get right: names, ticket prefixes, jargon (e.g. `EN-`, `Confluence`). |
| `hotkey_mode` | `hold` (push-to-talk) or `toggle`. |
| `api_base_url` | Override the Anthropic endpoint — a gateway, proxy, or a local mock. |
| `api_headers` | Extra request headers for gateways. The Keychain key always wins. |
| `denied_bundle_ids` | Apps never sent anywhere; raw transcript only. Overrides everything. |
| `edit_opt_in_bundle_ids` | Apps whose focused field text may be read, enabling draft edits. |
| `context_opt_in_bundle_ids` | Apps whose surrounding on-screen text may be read. |
| `context_char_cap` / `field_char_cap` | Ceilings on how much surrounding/field text is read. Keeps the most recent. |
| `modes` | Per-app rewriting: match by bundle id or window title, with a custom prompt. |
| `show_overlay` / `sound_feedback` | Turn the status panel and sounds on or off. |
| `insert_raw_first` | Insert the raw transcript immediately, then replace it when the rewrite returns. Off by default. |

## Troubleshooting

- **Dictation stops working after an update.** macOS reset the Accessibility grant. Remove Wormtongue in System Settings → Privacy & Security → Accessibility and add it again, then restart it.
- **The words come out wrong.** Accuracy depends on the model and language. Set `whisper_language` to your language, or move to a bigger model.
- **Nothing happens when I hold the hotkey.** Check that Input Monitoring is granted and that the hotkey isn't already claimed by another app.
- **Latency matters.** The target is under ~1.5 s from release to inserted text. Every dictation logs a per-stage breakdown you can view from the menu.

## For developers

Build the app bundle (requires macOS 14+, Apple Silicon, and a Swift 6 / Xcode 16 toolchain):

```sh
./Scripts/bundle.sh release
open build/Wormtongue.app
```

Run everything that can be checked without a running GUI (core build, tests, source parsing, structural rules):

```sh
./Scripts/check.sh
```

The codebase is split so the logic in `Sources/WormtongueCore` is platform-free and covered by tests; the macOS app lives in `Sources/Wormtongue`.
