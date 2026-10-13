#!/bin/zsh
# Builds build/Jarvis.app from the Swift package (no Xcode required).
# Usage: scripts/build_app.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Jarvis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Jarvis" "$APP/Contents/MacOS/Jarvis"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for local runs, no developer account needed.
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"

# V0.11: the JARVIS-owned test fixture for Computer Use (a separate bundle with its own identifier; never part of Jarvis.app).
FIX="build/JarvisFixture.app"
rm -rf "$FIX"
mkdir -p "$FIX/Contents/MacOS" "$FIX/Contents/Resources"
cp "$BIN_DIR/JarvisFixture" "$FIX/Contents/MacOS/JarvisFixture"
cp Resources/FixtureInfo.plist "$FIX/Contents/Info.plist"
codesign --force --sign - "$FIX" >/dev/null
codesign --verify --strict "$FIX"

echo "Built $APP ($CONFIG) and $FIX"
