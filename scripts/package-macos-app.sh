#!/bin/sh
# Builds dist/Teriyaki.app, the native macOS app: SwiftUI on top of a statically linked chiaki-lib.
set -e
cd "$(dirname "$0")/.."
BP=$(brew --prefix)
APP=dist/Teriyaki.app
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

if [ ! -f build-lib/build.ninja ]; then
	PATH="$BP/opt/protobuf@29/bin:$PATH" cmake -S . -B build-lib -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF \
		-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
		-DCHIAKI_ENABLE_SPEEX=OFF -DPYTHON_EXECUTABLE="$PWD/.venv/bin/python" \
		-DCMAKE_PREFIX_PATH="$BP/opt/openssl@3;$BP/opt/protobuf@29"
fi
PATH="$BP/opt/protobuf@29/bin:$PATH" cmake --build build-lib --target chiaki-lib

# The macOS 27 SDK needs Xcode's SwiftUI macro plugin; the 26.5 SDK builds with the command line tools alone.
[ -d "$SDK" ] && [ ! -d /Applications/Xcode.app ] && export SDKROOT="$SDK"
swift build -c release --package-path macos

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp macos/.build/release/Teriyaki "$APP/Contents/MacOS/"
cp macos/Info.plist "$APP/Contents/"
cp macos/Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
