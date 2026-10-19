#!/bin/bash
# Stops LightsOut and removes the app, its login agent and its settings.
launchctl bootout "gui/$(id -u)/com.lightsout.app" 2>/dev/null || true
pkill -x LightsOut 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.lightsout.app.plist"
rm -rf "$HOME/Applications/LightsOut.app" "/Applications/LightsOut.app"
defaults delete com.lightsout.app 2>/dev/null || true
echo "LightsOut removed."
