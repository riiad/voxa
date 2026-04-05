#!/bin/bash
set -e

VOXA_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$HOME/.voxa/models"
CONFIG_DIR="$HOME/.voxa"
MODEL_NAME="ggml-small.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"

echo "=== Voxa Setup ==="

# Check/install dependencies
echo ""
echo "--- Dependencies ---"

if ! command -v ffmpeg &>/dev/null; then
    echo "Installing ffmpeg..."
    brew install ffmpeg
else
    echo "ffmpeg: OK"
fi

if ! command -v whisper-cli &>/dev/null; then
    echo "Installing whisper-cpp..."
    brew install whisper-cpp
else
    echo "whisper-cpp: OK"
fi

# Download model
echo ""
echo "--- Whisper Model ($MODEL_NAME) ---"
mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "Downloading $MODEL_NAME (~466 MB)..."
    curl -L -o "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
    echo "Model downloaded."
else
    echo "Model already present: $MODEL_DIR/$MODEL_NAME"
fi

# Config
echo ""
echo "--- Configuration ---"
if [ ! -f "$CONFIG_DIR/config" ]; then
    cp "$VOXA_DIR/config.default" "$CONFIG_DIR/config"
    echo "Created default config at $CONFIG_DIR/config"
else
    echo "Config already exists: $CONFIG_DIR/config"
fi

# Compile voxad
echo ""
echo "--- Compiling voxad ---"
swiftc -O -o "$VOXA_DIR/voxad" "$VOXA_DIR/voxad.swift" -framework Cocoa -framework Carbon
echo "Compiled voxad"

# Make scripts executable
chmod +x "$VOXA_DIR/voxa.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "IMPORTANT: Grant Accessibility permission to voxad in:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  Also grant Microphone permission to Terminal/iTerm."
echo ""
echo "To start voxa daemon:"
echo "  $VOXA_DIR/voxad"
echo ""
echo "To configure the key binding, edit: ~/.voxa/config"
echo ""
echo "Usage: Hold Right Cmd to record, release to transcribe and paste."
