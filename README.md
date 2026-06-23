<div align="center">

# 🎙 Murmure

**Local voice dictation for macOS.**
Press a key, speak, and get clean text right where your cursor is — 100% on your Mac.

[![Platform](https://img.shields.io/badge/macOS-14%2B-black)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![On-device](https://img.shields.io/badge/100%25-on--device-34c759)](#privacy)

### [▶ Try the live demo](https://hugo291.github.io/Murmure/)

</div>

---

Murmure is a tiny menu-bar app. You hold a key, talk, and it transcribes your speech **locally** (no cloud, no account), runs it through a **local AI** to clean up filler words and punctuation, and pastes the result at your cursor — in any app, including the browser.

It's the privacy-respecting, free, open-source take on tools like Wispr Flow or Typeless.

## Why Murmure

- **Truly private** — speech recognition ([whisper.cpp](https://github.com/ggerganov/whisper.cpp)) and AI cleanup ([LM Studio](https://lmstudio.ai) / [Ollama](https://ollama.com)) run entirely on your Mac. Nothing ever leaves the machine.
- **Clean text, not a transcript** — a local LLM removes "um", "uh", stutters and repetitions, fixes punctuation and casing, while keeping *your* words and style.
- **Pastes anywhere** — native fields, Electron apps, and web inputs (Chrome included).
- **Live feedback** — a Spotlight-style bar shows a real-time audio spectrum while you speak, then a thinking indicator while it processes.
- **Live preview** — your words appear in real time above the overlay as you talk (Apple's on-device speech), then vanish; the final pasted text still comes from whisper.
- **Learns your vocabulary** — correct a transcript and Murmure remembers the term, then reuses it to transcribe better next time.
- **Editable shortcuts** — rebind every command from the menu, with conflict warnings.
- **Parallel dictations** — fire several at once; they're delivered in the order you started them, so your text never gets scrambled.
- **Mutes system audio** while recording (like Typeless), and restores it after.
- **English & French** interface, switchable from the menu.

## Install

### Option A — one command (recommended)

Installs the dependencies, downloads the speech model, builds and signs the app, and launches it. Everything works out of the box:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hugo291/Murmure/main/install.sh)"
```

The installer pulls in Homebrew, `whisper-cpp`, LM Studio and `ollama` if you don't already have them.

### Option B — download the app

Grab the latest **[Murmure.dmg](https://github.com/Hugo291/Murmure/releases/latest)**, open it, and drag **Murmure** into **Applications**.

Murmure is free and self-signed (not notarized by Apple), so the **first launch** needs one extra step:

1. Double-click Murmure → macOS says it can't verify the developer. Click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the Murmure message — then confirm.
   *(Equivalent in Terminal: `xattr -dr com.apple.quarantine /Applications/Murmure.app`.)*

The DMG ships the **app only** — the speech and AI engines aren't bundled. Install them once with Homebrew:

```bash
brew install whisper-cpp ollama          # speech-to-text + local AI cleanup
```

Then, from Murmure's menu, download a **transcription model** and an **AI model** in one click each.

Requirements: **macOS 14 (Sonoma) or later**.

### First launch

Murmure lives in the menu bar (the 🎙 mic, top-right). On first run, grant three permissions in **System Settings › Privacy & Security**:

| Permission | Why |
|---|---|
| **Microphone** | to hear you |
| **Input Monitoring** | to detect the Fn key globally |
| **Speech Recognition** | optional — for the real-time live preview (on-device) |
| **Accessibility** | to paste text at the cursor |

> **Tip:** in System Settings › Keyboard, set *"Press 🌐/Fn key to"* → *"Do Nothing"* so Fn is free for dictation.

## Usage

| Shortcut | Action |
|---|---|
| **Fn** | Start / stop dictation (tap to start, tap again to transcribe & paste) |
| **Esc** | Cancel the current recording or processing |
| **⌘L** | Paste the last dictation again |
| **⌘R** | Rewrite the selected text (strip filler & repetition, keep the meaning) |

All shortcuts are editable: **menu › Settings › Commands › Edit shortcuts…**

Press **Fn**, talk, press **Fn** again. The text lands at your cursor. That's it.

## How it works

```
  Fn ─► record (AVAudioEngine) ─► whisper.cpp (large-v3-turbo) ─► local LLM (Ollama) ─► paste at cursor
        live spectrum overlay       on-device transcription        filler/punctuation cleanup
```

Everything runs locally. The speech model (`large-v3-turbo`, ~1.5 GB) lives in
`~/Library/Application Support/Murmure/`. AI cleanup prefers **LM Studio** (MLX models —
the best option on Apple Silicon) and falls back to **Ollama** automatically if LM Studio
isn't running, so cleanup always works.

Tune all of this from **Settings**:
- **AI touch-up** — raw text, light cleanup (default), or full rewrite.
- **AI engine** — pick any model already installed in Ollama or LM Studio (the menu lists them live). If you have none, *Download a model…* fetches Gemma in one click — for Ollama (`ollama pull`) or LM Studio (MLX). *Test current model* benchmarks its response time.
- **Transcription model** — choose among the whisper models you have, or *Download a model…* to grab another size (tiny → large-v3) from Hugging Face in one click, with a live progress bar.
- **Dictation language** — French, English, or auto.
- **Language** — interface language (English by default, French available).

## Privacy

Murmure makes **zero network requests** for its core function. Audio, transcripts and your learned vocabulary stay in `~/Library/Application Support/Murmure/` on your Mac. The real-time live preview uses Apple's speech recognition with `requiresOnDeviceRecognition = true`, so it stays on-device too. The only downloads are the one-time model files (from Hugging Face / Ollama) during install.

## Build from source

```bash
git clone https://github.com/Hugo291/Murmure.git
cd Murmure
./install.sh        # full setup (deps + model + build + launch)
# or, if deps are already in place:
./build.sh          # just build & sign Murmure.app into ~/Applications
swift build         # plain debug build
```

Pure Swift / AppKit, built with SwiftPM — no Xcode project required.

## Tech

- Swift 6 · AppKit · SwiftUI (settings windows)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for on-device transcription
- [Ollama](https://ollama.com) / [LM Studio](https://lmstudio.ai) for local LLM cleanup
- Accelerate / vDSP for the live spectrum and voice-activity gate
- `CGEventTap` for global shortcuts, the Accessibility API for cursor-position pasting

## Contributing

Issues and pull requests are welcome. Murmure is intentionally small and focused — please open an issue to discuss larger changes first.

## License

[MIT](LICENSE) © 2026 Hugo. Use it, fork it, ship it.
