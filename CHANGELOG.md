# Changelog

All notable changes to Murmure are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-11-01

### Added

- **Parakeet v3** (NVIDIA, Core ML via FluidAudio) as a transcription model — about 10× faster than
  Whisper turbo, slightly less accurate.
- **Engine priority list** — add AI models by family (Ollama · CPU, Ollama Cloud, Ollama · MLX,
  LM Studio), drag them into order; the first engine that answers does the cleanup, the others are
  fallbacks. Per-row state (server off, model missing, in use) and per-engine timing.
- **Ollama Cloud** engines (opt-in): the dictated text is processed on ollama.com.
- **GPU busy: MLX engines last** — when another process holds the GPU, CPU engines go first.
- **Screen context** — reads the conversation shown in the window to restore mis-heard names and
  stay on topic; never sent to a cloud engine.
- **History** — dictations grouped by field with "Copy all"; for Claude, the app icon and a cleaned
  digest of the visible conversation (no model, token, cost or tool-run noise).
- **Model under the spectrum** (toggle) — transcription model, then the cleanup engine at work.
- **Skip the AI touch-up** with a lone Shift tap: pastes the raw transcript right away.
- **Optional audio replay** — keep audio 20 minutes to replay or re-transcribe from History.
- **Google Cast TVs and speakers** muted while dictating (opt-in per device, via `catt`).
- French numbers written as digits ("vingt-trois" → 23), deterministic.
- Restart Murmure from the menu.

### Changed

- New overlay card: centered "phase · timer" line under the spectrum, compact stacked cards, and the
  stack follows the screen of the target field.
- LM Studio lists every downloaded language model (loaded or not), not only the loaded ones.
- The "words to validate" queue lives only in the Dictionary, no longer in History.

## [1.0.0] — 2026-06-24

First public release. Murmure is a tiny menu-bar app for macOS that turns your
voice into clean text at the cursor, 100% on-device — no cloud, no account.

### Added

- **Local voice dictation** — press a key, speak, press again; the text lands at
  your cursor in any app (native fields, Electron apps, and web inputs incl. Chrome).
- **On-device speech recognition** via [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
  (`large-v3-turbo` by default). Nothing ever leaves the Mac.
- **AI cleanup** — a local LLM strips "um/uh", stutters and repetitions, and fixes
  punctuation and casing while keeping your words and style. Prefers
  [LM Studio](https://lmstudio.ai) (MLX, best on Apple Silicon), falls back to
  [Ollama](https://ollama.com) automatically.
- **Global hotkey** — dictation is driven by a system-level hotkey (Fn by default),
  so it works from any app without bringing Murmure to the foreground.
- **Runs as a background menu-bar service** — no Dock icon and no ⌘-Tab entry; just
  the 🎙 in the menu bar. The app stays silent in the background and only comes to the
  foreground while a window is open. Launches at login.
- **Live preview** — your words appear in real time above the overlay as you talk
  (Apple's on-device speech), then vanish; the final pasted text comes from whisper.
- **Spotlight-style overlay** with a real-time audio spectrum while recording and a
  thinking indicator while processing.
- **Learns your vocabulary** — correct a transcript and Murmure remembers the term,
  then reuses it to transcribe better next time.
- **History & dictionary** window with a shared word-validation queue.
- **Editable shortcuts** — rebind every command from the menu, with conflict warnings.
- **Parallel dictations** — fire several at once; they're delivered in the order you
  started them, so your text never gets scrambled.
- **Extra commands** — paste the last dictation again, and rewrite the selected text
  (strip filler & repetition, keep the meaning).
- **One-click model downloads** for whisper and the AI cleanup model.
- **Mutes system audio while recording** and restores it afterwards.
- **English & French** interface, switchable from the menu.

### Requirements

- macOS 14 (Sonoma) or later.
- The installer pulls in Homebrew, `whisper-cpp` and `ollama` if missing.

[1.0.0]: https://github.com/Hugo291/Murmure/releases/tag/v1.0.0
