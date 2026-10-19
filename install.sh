#!/bin/bash
# Builds LightsOut from source, puts it in ~/Applications and opens it.
# On first launch the app registers itself to start at login.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

launchctl bootout "gui/$(id -u)/com.lightsout.app" 2>/dev/null || true  # stop the login-started copy
pkill -x LightsOut 2>/dev/null || true                                    # and any other running copy
rm -rf "$HOME/Applications/LightsOut.app"
mkdir -p "$HOME/Applications"
cp -R build/LightsOut.app "$HOME/Applications/"
open "$HOME/Applications/LightsOut.app"
echo "LightsOut installed. Look for the moon icon in your menu bar (Cmd-drag it to move it)."
