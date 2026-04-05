# Voxa

Lightweight, free, local speech-to-text for macOS. A minimal alternative to SuperWhisper using [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Hold a key, speak, release — your words are transcribed and pasted into the active app.

## Features

- **Push-to-talk** — hold Right Cmd (configurable) to record, release to transcribe
- **100% local** — no cloud, no API, no account, no cost
- **Auto-paste** — transcribed text is copied to clipboard and pasted automatically
- **Recording indicator** — Dynamic Island-style overlay with pulsing red dot
- **Auto-start** — launches automatically at login via LaunchAgent
- **Fast** — uses whisper.cpp with Metal acceleration on Apple Silicon
- **French by default** — optimized for French, configurable for any language

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
1. Install `ffmpeg` and `whisper-cpp` via Homebrew
2. Download the Whisper `small` model (~466 MB)
3. Build the `Voxa.app` bundle
4. Install a LaunchAgent for auto-start at login

On first launch, grant permissions in **System Settings > Privacy & Security**:
- **Accessibility** — allow Voxa
- **Microphone** — allow Voxa (popup on first use)

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

# Whisper settings
language = fr
# model = ggml-small.bin
```

### Key binding options

Modifier-only keys (push-to-talk):
`right_cmd`, `left_cmd`, `right_shift`, `left_shift`, `right_ctrl`, `left_ctrl`, `right_alt`, `left_alt`

Key combos:

```
key = space
modifiers = ctrl, shift
```

Restart Voxa after changing the config.

## How it works

```
Voxa.app (Swift daemon)
  ├── detects key press → voxa.sh start
  │     └── ffmpeg records mic → ~/.voxa/tmp/recording.wav
  ├── detects key release → voxa.sh stop
  │     └── whisper-cli transcribes → pbcopy → auto-paste
  └── shows/hides recording overlay
```

## Uninstall

```bash
chmod +x uninstall.sh
./uninstall.sh
```

This stops the daemon, removes the LaunchAgent, and cleans up `~/.voxa`. The source code is not deleted.

## License

MIT
