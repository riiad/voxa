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

# Build Voxa.app bundle
echo ""
echo "--- Building Voxa.app ---"
APP_DIR="$VOXA_DIR/Voxa.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.voxa.daemon</string>
    <key>CFBundleName</key>
    <string>Voxa</string>
    <key>CFBundleExecutable</key>
    <string>voxad</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voxa needs microphone access to record speech for transcription.</string>
</dict>
</plist>
INFOPLIST

if swiftc -O -o "$APP_DIR/Contents/MacOS/voxad" "$VOXA_DIR/voxad.swift" -framework Cocoa -framework Carbon -framework AVFoundation 2>&1; then
    echo "Compiled voxad"
else
    echo "ERROR: Compilation failed. Make sure Xcode Command Line Tools are installed:"
    echo "  xcode-select --install"
    exit 1
fi

# Ad-hoc sign the bundle so TCC can properly identify it.
# Without this, the linker-signed binary has an unstable identity and
# Accessibility permissions silently fail for CGEvent posting.
codesign --force --sign - --identifier com.voxa.daemon --deep "$APP_DIR"
echo "Signed Voxa.app (ad-hoc, identifier=com.voxa.daemon)"


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
