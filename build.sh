#!/bin/bash
# Compiles LightsOut.m into build/LightsOut.app: one binary for Apple Silicon + Intel, macOS 10.13+.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Building LightsOut needs Apple's free Command Line Tools. Run:  xcode-select --install"
  exit 1
fi

APP=build/LightsOut.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
compile() {
  clang -fobjc-arc -O2 -Wno-objc-method-access -mmacosx-version-min=10.13 "$@" \
    -framework Cocoa -framework IOKit LightsOut.m -o "$APP/Contents/MacOS/LightsOut"
}
# Older toolchains can't target arm64; they build for the current Mac only.
compile -arch arm64 -arch x86_64 2>/dev/null || compile
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null   # ad-hoc signature: required to run on Apple Silicon
echo "built $APP"
