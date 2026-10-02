#!/bin/sh
# Builds dist/Chiaki.app: the native SwiftUI front end with the streaming engine (dist/chiaki-ng.app) inside.
set -e
cd "$(dirname "$0")/.."
APP=dist/Chiaki.app
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

[ -d dist/chiaki-ng.app ] || ./scripts/package-macos.sh
# The macOS 27 SDK needs Xcode's SwiftUI macro plugin; the 26.5 SDK builds with the command line tools alone.
[ -d "$SDK" ] && [ ! -d /Applications/Xcode.app ] && export SDKROOT="$SDK"
swift build -c release --package-path macos

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp macos/.build/release/Chiaki "$APP/Contents/MacOS/"
cp macos/Info.plist "$APP/Contents/"
cp gui/chiaking.icns "$APP/Contents/Resources/AppIcon.icns"
cp -a dist/chiaki-ng.app "$APP/Contents/Helpers/"
codesign --force --sign - "$APP"
echo "Built $APP"
