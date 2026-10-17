#!/bin/zsh
# Builds the DEVELOPER bundle build/dev/JarvisDev.app (bundle id dev.jarvis.Jarvis.dev, name "JARVIS Dev") from the Swift package (no Xcode required).
# It is NOT the product: the installable app is /Applications/JARVIS.app (scripts/package-app.sh + scripts/install-app.sh, bundle id dev.jarvis.Jarvis). A different bundle id keeps
# developer builds out of the installed app's UserDefaults domain, Launch Services identity and macOS privacy (TCC) entries.
# Usage: scripts/build_app.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

OUT="build/dev"
APP="$OUT/JarvisDev.app"
rm -rf build/Jarvis.app build/JarvisFixture.app "$APP"        # (the pre-fix-3 locations: never leave a confusing second "Jarvis.app" behind)
mkdir -p "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Jarvis" "$APP/Contents/MacOS/Jarvis"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.jarvis.Jarvis.dev" -c "Set :CFBundleName JARVIS Dev" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for local runs, no developer account needed.
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"

# V0.11: the JARVIS-owned test fixture for Computer Use (a separate bundle with its own identifier; never part of Jarvis.app).
FIX="$OUT/JarvisFixture.app"
rm -rf "$FIX"
mkdir -p "$FIX/Contents/MacOS" "$FIX/Contents/Resources"
cp "$BIN_DIR/JarvisFixture" "$FIX/Contents/MacOS/JarvisFixture"
cp Resources/FixtureInfo.plist "$FIX/Contents/Info.plist"
codesign --force --sign - "$FIX" >/dev/null
codesign --verify --strict "$FIX"

echo "Built $APP ($CONFIG) and $FIX"
