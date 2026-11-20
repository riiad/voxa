#!/bin/bash
set -e

VOXA_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$HOME/.voxa/models"
CONFIG_DIR="$HOME/.voxa"
MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
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
    echo "Downloading $MODEL_NAME (~550 MB)..."
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

# Build Voxa.app bundle
echo ""
echo "--- Building Voxa.app ---"
APP_DIR="$VOXA_DIR/Voxa.app"
"$VOXA_DIR/build.sh"

# Install LaunchAgent
echo ""
echo "--- LaunchAgent ---"
PLIST_NAME="com.voxa.daemon.plist"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_NAME"
mkdir -p "$PLIST_DIR"

# Stop existing service if running
launchctl bootout "gui/$(id -u)/com.voxa.daemon" 2>/dev/null || true
pkill -f "Voxa.app" 2>/dev/null || true

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.voxa.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>-a</string>
        <string>$APP_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "LaunchAgent installed and started"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Voxa will now start automatically at login."
echo ""
echo "IMPORTANT: On first launch, grant these permissions in System Settings:"
echo "  1. Privacy & Security > Accessibility: allow Voxa"
echo "  2. Privacy & Security > Microphone: allow Voxa (popup on first use)"
echo ""
echo "Commands:"
echo "  Stop:    launchctl bootout gui/\$(id -u)/com.voxa.daemon"
echo "  Start:   launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
echo "  Manual:  open $APP_DIR"
echo ""
echo "Config: ~/.voxa/config"
echo ""
echo "Usage: Hold Right Cmd to record, release to transcribe and paste."
echo ""
echo "Note: each rebuild changes the app's ad-hoc signature, so macOS drops the"
echo "Accessibility permission. Re-enable Voxa in System Settings after running setup again."
