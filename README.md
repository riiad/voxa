# Voxa

Lightweight, free, local speech-to-text for macOS. A minimal alternative to SuperWhisper using [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Hold a key, speak, release — your words are transcribed and pasted into the active app.

## Features

- **Push-to-talk** — hold Right Cmd (configurable) to record, release to transcribe. Quick taps are ignored
- **100% local** — no cloud, no API, no account, no cost
- **Auto-paste** — transcribed text is pasted into the active app, then your previous clipboard is restored
- **Fast** — the model stays loaded in a local `whisper-server` while you dictate (no model reload per dictation), and is unloaded after 10 idle minutes
- **Recording indicator** — Dynamic Island-style overlay with elapsed time and pulsing red dot
- **Auto-start** — launches automatically at login via LaunchAgent
- **Metal** — whisper.cpp with Metal acceleration on Apple Silicon
- **French by default** — optimized for French, configurable for any language
- **Hallucination filter** — silent takes are never sent to whisper, and common whisper artifacts are discarded
- **Shortcut-safe** — holding Right Cmd for a shortcut (Cmd+Tab, Cmd+C…) cancels the take instead of dictating

## Requirements

- macOS (Apple Silicon recommended)
- [Homebrew](https://brew.sh)

## Setup

```bash
git clone https://github.com/riiad/voxa.git
cd voxa
chmod +x setup.sh
./setup.sh
```

The setup script will:
1. Install `whisper-cpp` via Homebrew
2. Download the Whisper `large-v3-turbo` model (quantized, ~550 MB)
3. Build and sign the `Voxa.app` bundle
4. Install a LaunchAgent for auto-start at login

On first launch, grant permissions in **System Settings > Privacy & Security**:
- **Accessibility** — allow Voxa (required for auto-paste)
- **Microphone** — allow Voxa (popup on first use)

> Voxa is signed ad-hoc, so every rebuild gives it a new identity and macOS silently drops the Accessibility permission. After re-running `setup.sh`, toggle Voxa off and on in the Accessibility list.

## Usage

Hold **Right Cmd** to record, release to transcribe and auto-paste.

### Managing the daemon

```bash
# Stop
launchctl bootout gui/$(id -u)/com.voxa.daemon

# Start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.voxa.daemon.plist

# Or launch manually
open ~/Code/voxa/Voxa.app
```

## Configuration

Edit `~/.voxa/config`:

```
# Push-to-talk key
key = right_cmd

# Hold delay in ms before recording starts (default: 300)
# Quick taps below this threshold are ignored
# delay = 300

# Whisper settings
language = fr
# model = ggml-large-v3-turbo-q5_0.bin   (ggml-small.bin: faster, less accurate)

# Vocabulary hint: names, jargon and spellings whisper should prefer
# prompt = Jean-Baptiste, KPI, Cmd+Tab

# Skip takes quieter than this peak level (dBFS); voxad.log prints each take's peak
# silence_db = -50

# Restore the previous clipboard after pasting
# restore_clipboard = true

# Minutes without dictation before whisper-server is stopped to free memory
# server_idle_minutes = 10
```

Config errors are reported in a notification and the default value is used instead.

### Key binding options

Modifier-only keys (push-to-talk):
`right_cmd`, `left_cmd`, `right_shift`, `left_shift`, `right_ctrl`, `left_ctrl`, `right_alt`, `left_alt`

Key combos:

```
key = space
modifiers = ctrl, shift
```

Restart Voxa after changing the config.

## Development

```bash
./build.sh                                   # compile, run the self-test, sign Voxa.app (installs nothing)
Voxa.app/Contents/MacOS/voxad --self-test     # config parser and transcript filter checks
Voxa.app/Contents/MacOS/voxad --transcribe file.wav   # run a 16 kHz mono wav through the real pipeline
```

Logs: `~/.voxa/tmp/voxad.log` (rotated at 1 MB, dictated text is never logged) and `~/.voxa/tmp/whisper.log`.

## How it works

```
Voxa.app (Swift daemon)
  ├── detects key hold → waits 300ms hold delay
  │     ├── released before delay, or another key pressed → ignored (normal key use)
  │     └── held past delay → starts recording + warms up whisper-server
  │           └── AVFoundation captures mic → ~/.voxa/tmp/<uuid>.wav
  ├── detects key release → stops recording
  │     ├── silent take → dropped
  │     └── whisper-server transcribes (HTTP, localhost) → clipboard → auto-paste → clipboard restored
  ├── stops whisper-server after 10 idle minutes
  └── shows/hides recording overlay with timer
```

## Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

This stops the daemon, removes the LaunchAgent, and cleans up `~/.voxa`. The source code is not deleted.

## Roadmap

- [ ] AI mode — reformulate transcription via LLM before pasting (Ollama for local, or API)
- [ ] Language switching on the fly
- [ ] Transcription history
- [ ] Menu bar icon

## License

MIT
