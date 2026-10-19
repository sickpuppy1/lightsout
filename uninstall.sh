#!/bin/bash
# Stops LightsOut and removes the app, its login agent, its lid-closed permission and its settings.
launchctl bootout "gui/$(id -u)/com.lightsout.app" 2>/dev/null || true
pkill -x LightsOut 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.lightsout.app.plist"

# Lid-closed mode: make sure sleep is back on, then remove the sudo rule (asks for your password).
if [ "$(defaults read com.lightsout.app lidModeEngaged 2>/dev/null)" = "1" ]; then
  sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0
fi
if [ -f /etc/sudoers.d/lightsout ]; then
  echo "Removing the lid-closed permission (/etc/sudoers.d/lightsout) needs your password:"
  sudo rm -f /etc/sudoers.d/lightsout
fi
rm -rf "$HOME/Applications/LightsOut.app" "/Applications/LightsOut.app"
defaults delete com.lightsout.app 2>/dev/null || true
echo "LightsOut removed."
