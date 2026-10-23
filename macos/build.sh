#!/bin/bash
# Builds VoiceBar.app with the Xcode Command Line Tools (no Xcode project) and
# installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/VoiceBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with Icon/make_icon.swift
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" \
    Sources/*.swift -o "$APP/Contents/MacOS/VoiceBar"
# macOS ties the Accessibility and Microphone grants to the signature. An ad-hoc
# signature changes with every build, so sign with the local certificate
# "VoiceBar Local Signing" (see README) when it exists, keeping the grants.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -p codesigning |
    awk '/"VoiceBar Local Signing"/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
    echo "warning: no 'VoiceBar Local Signing' certificate; signing ad hoc," \
         "so macOS will ask for permissions again after each rebuild" >&2
    IDENTITY=-
fi
codesign --force --sign "$IDENTITY" --identifier com.rstiskalek.voicebar "$APP"

# Move rather than copy: a second VoiceBar.app would also appear in Launchpad and Spotlight.
mkdir -p ~/Applications
rm -rf ~/Applications/VoiceBar.app
mv "$APP" ~/Applications/
echo "Installed ~/Applications/VoiceBar.app"
