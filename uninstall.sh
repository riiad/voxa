#!/bin/bash
echo "=== Voxa Uninstall ==="

# Stop daemon
echo ""
echo "--- Stopping Voxa ---"
launchctl bootout "gui/$(id -u)/com.voxa.daemon" 2>/dev/null || true
pkill -f "Voxa.app" 2>/dev/null || true
pkill -f voxad 2>/dev/null || true
pkill -f "ffmpeg.*voxa" 2>/dev/null || true
echo "Stopped"

# Remove LaunchAgent
echo ""
echo "--- Removing LaunchAgent ---"
rm -f "$HOME/Library/LaunchAgents/com.voxa.daemon.plist"
echo "Removed"

# Remove config and data
echo ""
echo "--- Removing ~/.voxa ---"
rm -rf "$HOME/.voxa"
echo "Removed"

echo ""
echo "=== Uninstall Complete ==="
echo ""
echo "Voxa has been stopped and its config/data removed."
echo "The source code in $(cd "$(dirname "$0")" && pwd) was NOT deleted."
echo ""
echo "To also remove the source code:"
echo "  rm -rf $(cd "$(dirname "$0")" && pwd)"
echo ""
echo "To uninstall dependencies (optional):"
echo "  brew uninstall whisper-cpp"
echo "  brew uninstall skhd  # if installed"
echo ""
echo "Remember to remove Voxa from:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  System Settings > Privacy & Security > Microphone"
