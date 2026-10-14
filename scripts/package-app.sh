#!/bin/zsh
# Builds the installable JARVIS.app (V0.15, docs/APP_PACKAGING.md): release build → bundle → icon → packaged setup scripts → signature → verification.
# Usage:  scripts/package-app.sh            → build/package/JARVIS.app
# Not needed to RUN JARVIS: it is how a release copy is produced. Never requires root, never touches ~/Library/Application Support/JARVIS, never uploads anything.
#
# Signing: JARVIS_SIGN_IDENTITY, else the first valid code-signing identity in the keychain (names only are read; no key material), else an AD-HOC signature.
#          Hardened runtime is on; the only entitlement is the microphone (Resources/Jarvis.entitlements). The app is NOT notarized (a private, local-use build).
set -euo pipefail
cd "${0:A:h:h}"

VERSION=$(sed -n 's/.*static let sourceVersion = "\([0-9.]*\)".*/\1/p' Sources/Jarvis/Core/Log.swift)
[ -n "$VERSION" ] || { echo "cannot read sourceVersion from Sources/Jarvis/Core/Log.swift"; exit 1; }
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain 2>/dev/null)" ] || COMMIT="$COMMIT-dirty"

echo "== Release build"
swift build -c release 2>&1 | tail -3
BIN_DIR="$(swift build -c release --show-bin-path)"

OUT="build/package"
APP="$OUT/JARVIS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/setup/scripts"
cp "$BIN_DIR/Jarvis" "$APP/Contents/MacOS/Jarvis"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
$PB -c "Add :JarvisBuildCommit string $COMMIT" "$APP/Contents/Info.plist"

echo "== Icon"
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$ICON"; echo "using Resources/AppIcon.icns"
else
  rm -rf "$OUT/AppIcon.iconset"; swift scripts/make-app-icon.swift "$OUT/AppIcon.iconset" >/dev/null
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$ICON"; rm -rf "$OUT/AppIcon.iconset"; echo "generated the temporary icon (replace with Resources/AppIcon.icns)"
fi
$PB -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

echo "== Packaged setup scripts (the typed Set Up buttons run these; models are NOT bundled)"
SETUP="$APP/Contents/Resources/setup/scripts"
for f in setup_local_ai.sh setup_memory_ai.sh setup_vision_ai.sh setup_voice_ai.sh; do cp -p "scripts/$f" "$SETUP/$f"; chmod 755 "$SETUP/$f"; done
for d in local-ai memory-ai vision-ai voice-ai; do
  mkdir -p "$SETUP/$d"
  # worker scripts + pinned requirements only: no benchmark material, no bytecode
  for f in scripts/$d/*.py scripts/$d/requirements*.txt(N); do cp -p "$f" "$SETUP/$d/"; done
done

echo "== Signature"
IDENTITY="${JARVIS_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p' | head -1); fi
if [ -n "$IDENTITY" ]; then SIGNKIND="identity: $IDENTITY"; else IDENTITY="-"; SIGNKIND="ad-hoc (no code-signing identity on this Mac)"; fi
codesign --force --options runtime --entitlements Resources/Jarvis.entitlements --sign "$IDENTITY" "$APP"
echo "signed with $SIGNKIND"

echo "== Verification"
fail=0
ok()  { print "PASS  $1"; }
bad() { print "FAIL  $1"; fail=$((fail+1)); }
plutil -lint "$APP/Contents/Info.plist" >/dev/null && ok "Info.plist lints" || bad "Info.plist lints"
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "dev.jarvis.Jarvis" ] && ok "bundle identifier dev.jarvis.Jarvis" || bad "bundle identifier"
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] && ok "version $VERSION (build $BUILD)" || bad "version"
[ "$(plutil -extract LSUIElement raw "$APP/Contents/Info.plist")" = "true" ] && ok "menu-bar application (LSUIElement)" || bad "LSUIElement"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "icon present" || bad "icon"
[ -x "$APP/Contents/MacOS/Jarvis" ] && lipo -archs "$APP/Contents/MacOS/Jarvis" | grep -q arm64 && ok "arm64 executable" || bad "executable"
codesign --verify --strict --deep "$APP" 2>/dev/null && ok "signature valid (strict, deep)" || bad "signature valid"
flags=$(codesign -dv "$APP" 2>&1 || true)
[[ "$flags" == *runtime* ]] && ok "hardened runtime" || bad "hardened runtime"
ent=$(codesign -d --entitlements :- "$APP" 2>/dev/null | grep -o 'com.apple.[a-z.\-]*' | sort -u | tr '\n' ' ')
[ "$ent" = "com.apple.security.device.audio-input " ] && ok "entitlements: only the microphone" || bad "entitlements are '$ent'"
mut=$(find "$APP" \( -name '*.sqlite*' -o -name '*.db' -o -name '*.gguf' -o -name '*.safetensors' -o -name '*.onnx' -o -name '*.npz' -o -name '*.bin' -o -name '*.mlpackage' \) | head -3)
[ -z "$mut" ] && ok "no database and no model inside the bundle" || bad "mutable or model files in the bundle: $mut"
size=$(du -sk "$APP" | cut -f1); [ "$size" -lt 150000 ] && ok "bundle size $((size/1024)) MB" || bad "bundle is $((size/1024)) MB"
[ -x "$SETUP/setup_local_ai.sh" ] && [ -f "$SETUP/voice-ai/jarvis_stt_worker.py" ] && ok "packaged setup scripts are present and executable" || bad "packaged setup scripts"
[ -z "$(find "$APP/Contents/Resources" -name 'Fixture*' -o -name '*Fixture*.app' | head -1)" ] && ok "no test fixture in the bundle" || bad "fixture in the bundle"
spctl --assess --type execute "$APP" >/dev/null 2>&1 && SP="accepted by Gatekeeper" || SP="not notarized — Gatekeeper would ask on a downloaded copy (a local build opened from Applications is fine)"
echo "INFO  $SP"
echo
echo "App:      $PWD/$APP"
echo "Version:  $VERSION (build $BUILD, commit $COMMIT)"
echo "Signing:  $SIGNKIND · hardened runtime · not notarized"
[ $fail -eq 0 ] && echo "PACKAGE OK" || { echo "PACKAGE FAILED ($fail)"; exit 1; }
