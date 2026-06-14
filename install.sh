#!/usr/bin/env bash
# Murmure — one-shot installer for macOS.
# Installs dependencies, the speech model, builds + signs the app, and launches it.
# Run from inside a clone, or straight from the web:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hugo291/Murmure/main/install.sh)"
set -euo pipefail

REPO="https://github.com/Hugo291/Murmure.git"
DEST="$HOME/Applications"
SUPPORT="$HOME/Library/Application Support/Murmure"
MODEL_FILE="$SUPPORT/ggml-large-v3-turbo.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
LLM_MODEL="gemma3:4b"

say()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n" "$1"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Murmure runs on macOS only."

# 1. Xcode Command Line Tools (provides swift)
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools…"
  xcode-select --install >/dev/null 2>&1 || true
  die "A system dialog opened. Finish the Command Line Tools install, then re-run this script."
fi
command -v swift >/dev/null 2>&1 || die "Swift not found. Install Xcode Command Line Tools and retry."
ok "Swift toolchain ready"

# 2. Homebrew
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
ok "Homebrew ready"

# 3. Dependencies: whisper.cpp (speech → text) + ollama (local AI cleanup)
say "Installing dependencies (whisper-cpp, ollama)…"
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list ollama      >/dev/null 2>&1 || brew install ollama
ok "whisper-cpp + ollama installed"

# 4. Source: build from this clone if possible, otherwise fetch a fresh copy
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$SELF" ] && [ -f "$SELF/Package.swift" ]; then
  SRC="$SELF"
  ok "Building from local checkout"
else
  SRC="${TMPDIR:-/tmp}/Murmure-src"
  say "Fetching Murmure source…"
  rm -rf "$SRC"
  git clone --depth 1 "$REPO" "$SRC"
fi

# 5. Speech model (~1.5 GB, one time) — required for transcription
mkdir -p "$SUPPORT"
if [ ! -f "$MODEL_FILE" ]; then
  say "Downloading the speech model (large-v3-turbo, ~1.5 GB — grab a coffee)…"
  curl -L --fail --progress-bar -o "$MODEL_FILE.part" "$MODEL_URL"
  mv "$MODEL_FILE.part" "$MODEL_FILE"
  ok "Speech model installed"
else
  ok "Speech model already present"
fi

# 6. Build + sign + install the app
say "Building Murmure…"
bash "$SRC/build.sh" "$DEST" >/dev/null
ok "Installed to $DEST/Murmure.app"

# 7. Local AI cleanup model — pulled in the BACKGROUND so it never blocks you.
#    Dictation works immediately; cleanup switches on once the model finishes downloading.
say "Setting up the local AI model in the background ($LLM_MODEL)…"
brew services start ollama >/dev/null 2>&1 || (ollama serve >/dev/null 2>&1 &)
( ollama pull "$LLM_MODEL" >/dev/null 2>&1 && \
  osascript -e 'display notification "AI cleanup is ready." with title "Murmure"' >/dev/null 2>&1 ) &
ok "AI model downloading in the background"

# 8. Launch
say "Launching Murmure…"
open "$DEST/Murmure.app"

cat <<'DONE'

  ────────────────────────────────────────────────
  Murmure is running — look for the 🎙 mic in your
  menu bar (top-right). On first launch, allow:
    • Microphone
    • Input Monitoring   (to read the Fn key)
    • Accessibility      (to paste at the cursor)
  Then press Fn, speak, press Fn again. Done.
  ────────────────────────────────────────────────
DONE
