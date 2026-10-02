#!/bin/sh
# Builds a self-contained chiaki-ng.app in dist/ from build/gui/chiaki.app (Homebrew dependencies).
set -e
cd "$(dirname "$0")/.."
BP=$(brew --prefix)
APP=dist/chiaki-ng.app
QMLDIR=$(mktemp -d)
trap 'rm -rf "$QMLDIR"' EXIT

rm -rf dist
mkdir -p dist
cp -a build/gui/chiaki.app "$APP"
cp -R gui/src/qml/. "$QMLDIR"
cp scripts/qtwebengine_import.qml "$QMLDIR"

deploy() {
	"$BP/opt/qt/bin/macdeployqt" "$APP" -qmldir="$QMLDIR" -libpath="$BP/lib"
}
deploy

ICD="$APP/Contents/Resources/vulkan/icd.d"
mkdir -p "$ICD"
cp "$BP/opt/molten-vk/lib/libMoltenVK.dylib" "$ICD"
sed 's|"library_path".*|"library_path": "./libMoltenVK.dylib",|' "$BP/etc/vulkan/icd.d/MoltenVK_icd.json" > "$ICD/MoltenVK_icd.json"
deploy

HELPER="$APP/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app/Contents"
[ -d "$HELPER" ] && [ ! -e "$HELPER/Frameworks" ] && ln -s ../../../../../../../Frameworks "$HELPER/Frameworks"
cp "$BP/opt/sdl3/lib/libSDL3.0.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/libSDL3.0.dylib"
ln -s libSDL3.0.dylib "$APP/Contents/Frameworks/libSDL3.dylib"
ln -s ../Frameworks/libSDL3.0.dylib "$APP/Contents/MacOS/libSDL3.dylib"
[ -e "$APP/Contents/Frameworks/vulkan" ] || ln -s libvulkan.1.dylib "$APP/Contents/Frameworks/vulkan"

install_name_tool -id @rpath/libSDL3.0.dylib "$APP/Contents/Frameworks/libSDL3.0.dylib"
chmod u+w "$ICD/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$ICD/libMoltenVK.dylib"

# macdeployqt leaves the web engine helper linked against Homebrew's Qt.
HELPER_BIN="$HELPER/MacOS/QtWebEngineProcess"
if [ -f "$HELPER_BIN" ]; then
	otool -L "$HELPER_BIN" | awk '/\/opt\/homebrew\/.*\.framework/ {print $1}' | while read -r dep; do
		install_name_tool -change "$dep" "@rpath/${dep#*/lib/}" "$HELPER_BIN"
	done
	install_name_tool -add_rpath @loader_path/../Frameworks "$HELPER_BIN" 2>/dev/null || true
fi

# --deep does not re-sign code under Resources.
codesign --force --sign - "$ICD/libMoltenVK.dylib"
codesign --force --entitlements gui/entitlements.xml --deep --sign - "$APP"
echo "Built $APP"
