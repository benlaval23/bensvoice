#!/bin/bash
# Builds BensVoice.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/BensVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BensVoice "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# Sign with a stable identity so macOS keeps Mic/Accessibility permissions across rebuilds.
IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --options runtime --entitlements Resources/entitlements.plist --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
pkill -x BensVoice 2>/dev/null || true
rm -rf ~/Applications/BensVoice.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/BensVoice.app (signed with: ${IDENTITY:-ad-hoc})"
