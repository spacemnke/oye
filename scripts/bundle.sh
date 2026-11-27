#!/usr/bin/env bash
# Builds Oye and wraps it into build/Oye.app and build/Oye.zip.
# Usage: scripts/bundle.sh [debug|release]
# Signed ad hoc for now, so macOS asks people to Open Anyway the first time. Developer ID signing
# and notarization come with the first test build for other people.
set -euo pipefail

CONFIG="${1:-release}"
cd "$(dirname "$0")/.."

swift build -c "$CONFIG" --arch arm64
swift build -c "$CONFIG" --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
INTEL_BIN="$(swift build -c "$CONFIG" --arch x86_64 --show-bin-path)"

APP="build/Oye.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BIN/Oye" "$INTEL_BIN/Oye" -output "$APP/Contents/MacOS/Oye"
lipo -info "$APP/Contents/MacOS/Oye"
cp Support/Info.plist "$APP/Contents/Info.plist"
BUILD="${OYE_BUILD:-1}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleShortVersionString 0.1.$BUILD" "$APP/Contents/Info.plist"
echo "Oye 0.1.$BUILD (build $BUILD)"

# Fonts and demo faces ship inside the SwiftPM resource bundle.
if [ -d "$BIN/Oye_Oye.bundle" ]; then
  cp -R "$BIN/Oye_Oye.bundle" "$APP/Contents/Resources/"
fi

# Anything linked dynamically ships as frameworks next to the binary.
mkdir -p "$APP/Contents/Frameworks"
for framework in "$BIN"/*.framework; do
  if [ -d "$framework" ]; then cp -R "$framework" "$APP/Contents/Frameworks/"; fi
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Oye"

codesign --force --deep --sign - "$APP"
# Naming the app by its bundle id keeps permissions from one ad hoc build to the next.
codesign --force --sign - --requirements '=designated => identifier "com.spacemnke.oye"' "$APP"

# The app must find its fonts and faces inside itself, not in the build folder.
test -f "$APP/Contents/Resources/Oye_Oye.bundle/Fonts/Inter-Regular.ttf" || { echo "Inter is missing from the app" >&2; exit 1; }

# Open it once, from somewhere else: if something is missing, it stops here instead of on your Mac.
CHECK="$(mktemp -d)"
cp -R "$APP" "$CHECK/Oye.app"
OYE_SMOKE_TEST=1 "$CHECK/Oye.app/Contents/MacOS/Oye" > "$CHECK/out.txt" 2>&1 &
SMOKE=$!
for _ in $(seq 1 30); do
  kill -0 "$SMOKE" 2>/dev/null || break
  sleep 1
done
if kill -0 "$SMOKE" 2>/dev/null; then
  kill "$SMOKE"
  echo "Oye didn't quit after its launch check" >&2
  exit 1
fi
wait "$SMOKE"
cat "$CHECK/out.txt"
grep -q "fonts found" "$CHECK/out.txt" || { echo "The packaged app couldn't find its fonts" >&2; exit 1; }

(cd build && ditto -c -k --keepParent Oye.app Oye.zip)

# The installer: double-click it and Oye lands in Applications.
pkgbuild --component "$APP" --install-location /Applications --identifier com.spacemnke.oye \
  --version "0.1.$BUILD" "build/Oye-Installer.pkg"
ls -la build/Oye.zip build/Oye-Installer.pkg
echo "Built $APP, build/Oye.zip and build/Oye-Installer.pkg"
