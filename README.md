# Voxa

Lightweight, free, local speech-to-text for macOS. A minimal alternative to SuperWhisper using [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Hold a key, speak, release — your words are transcribed and pasted into the active app.

## Features

- **Push-to-talk** — hold Right Cmd (configurable) to record, release to transcribe
- **100% local** — no cloud, no API, no account, no cost
- **Auto-paste** — transcribed text is copied to clipboard and pasted automatically
- **Recording indicator** — Dynamic Island-style overlay with pulsing red dot
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
3. Compile the `voxad` daemon
4. Create a default config at `~/.voxa/config`

Then grant permissions in **System Settings > Privacy & Security**:
- **Accessibility** — allow `voxad`
- **Microphone** — allow your terminal app

## Usage

Start the daemon:

```bash
./voxad
```

Hold **Right Cmd** to record, release to transcribe and auto-paste.

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

Restart `voxad` after changing the config.

## How it works

```
voxad (Swift daemon)
  ├── detects key press → voxa.sh start
  │     └── ffmpeg records mic → ~/.voxa/tmp/recording.wav
  ├── detects key release → voxa.sh stop
  │     └── whisper-cli transcribes → pbcopy → auto-paste
  └── shows/hides recording overlay
```

## License

MIT
