#!/bin/bash
set -e

VOXA_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$HOME/.voxa/models"
CONFIG_DIR="$HOME/.voxa"
MODEL_NAME="ggml-small.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"

echo "=== Voxa Setup ==="

# Pre-flight checks
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required. Install it from https://brew.sh"
    exit 1
fi

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
    TEMP_FILE="$MODEL_DIR/${MODEL_NAME}.tmp"
    echo "Downloading $MODEL_NAME (~466 MB)..."
    if curl --fail -L -o "$TEMP_FILE" "$MODEL_URL"; then
        mv "$TEMP_FILE" "$MODEL_DIR/$MODEL_NAME"
        echo "Model downloaded."
    else
        rm -f "$TEMP_FILE"
        echo "ERROR: Model download failed. Check your network connection."
        exit 1
    fi
else
    echo "Model already present: $MODEL_DIR/$MODEL_NAME"
fi

# Config
echo ""
echo "--- Configuration ---"
if [ ! -f "$CONFIG_DIR/config" ]; then
    if [ -f "$VOXA_DIR/config.default" ]; then
        cp "$VOXA_DIR/config.default" "$CONFIG_DIR/config"
        echo "Created default config at $CONFIG_DIR/config"
    else
        echo "WARNING: config.default not found, skipping config creation"
    fi
else
    echo "Config already exists: $CONFIG_DIR/config"
fi

# Create tmp directory
mkdir -p "$CONFIG_DIR/tmp"

# Compile voxad
echo ""
echo "--- Compiling voxad ---"
if swiftc -O -o "$VOXA_DIR/voxad" "$VOXA_DIR/voxad.swift" -framework Cocoa -framework Carbon 2>&1; then
    echo "Compiled voxad"
else
    echo "ERROR: Compilation failed. Make sure Xcode Command Line Tools are installed:"
    echo "  xcode-select --install"
    exit 1
fi

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
