#!/bin/bash
# Builds and signs Voxa.app, then runs the self-test. Does not install or restart anything.
# Usage: ./build.sh [output_dir]   (default: the repo directory)
set -e

VOXA_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-$VOXA_DIR}/Voxa.app"
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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
INFOPLIST

if ! swiftc -O -o "$APP_DIR/Contents/MacOS/voxad" "$VOXA_DIR/voxad.swift" \
        -framework Cocoa -framework AVFoundation -framework Accelerate; then
    echo "ERROR: Compilation failed. Make sure Xcode Command Line Tools are installed:"
    echo "  xcode-select --install"
    exit 1
fi
echo "Compiled voxad"

"$APP_DIR/Contents/MacOS/voxad" --self-test

# Ad-hoc sign the bundle so TCC can identify it. Without this, the linker-signed binary has an
# unstable identity and Accessibility permissions silently fail for CGEvent posting.
# Note: an ad-hoc identity changes with every build, so macOS drops the Accessibility grant
# after each rebuild — re-enable Voxa in System Settings > Privacy & Security > Accessibility.
codesign --force --sign - --identifier com.voxa.daemon "$APP_DIR"
echo "Signed $APP_DIR (ad-hoc, identifier=com.voxa.daemon)"
