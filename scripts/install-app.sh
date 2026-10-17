#!/bin/zsh
# Installs build/package/JARVIS.app as /Applications/JARVIS.app (V0.15). No root, no sudo, no network.
#   scripts/install-app.sh            → install or upgrade in place (atomic swap; the old copy is removed only after the new one is in place)
#   scripts/install-app.sh --dest ~/Applications   → install for this user only
# Never touches ~/Library/Application Support/JARVIS (your history, tasks, settings and models stay), never kills a running JARVIS, never overwrites a NEWER installed version.
set -euo pipefail
cd "${0:A:h:h}"
SRC="build/package/JARVIS.app"           # the STAGING copy: removed after a successful install so that only /Applications/JARVIS.app remains
DEST_DIR="/Applications"
if [[ "${1:-}" == "--dest" ]]; then DEST_DIR="${2:?--dest needs a folder}"; fi
DEST="$DEST_DIR/JARVIS.app"
[ -d "$SRC" ] || { echo "No $SRC — run scripts/package-app.sh first."; exit 1; }
codesign --verify --strict --deep "$SRC" 2>/dev/null || { echo "$SRC does not verify; rebuild it with scripts/package-app.sh."; exit 1; }
[ -d "$DEST_DIR" ] && [ -w "$DEST_DIR" ] || { echo "$DEST_DIR is not writable by this user. Drag $PWD/$SRC into it in Finder instead (no sudo is used here)."; exit 1; }

new=$(plutil -extract CFBundleShortVersionString raw "$SRC/Contents/Info.plist"); newb=$(plutil -extract CFBundleVersion raw "$SRC/Contents/Info.plist")
if [ -d "$DEST" ]; then
  old=$(plutil -extract CFBundleShortVersionString raw "$DEST/Contents/Info.plist" 2>/dev/null || echo 0); oldb=$(plutil -extract CFBundleVersion raw "$DEST/Contents/Info.plist" 2>/dev/null || echo 0)
  echo "Installed: $old (build $oldb) → new: $new (build $newb)"
  # a running JARVIS keeps its files open: ask the person to quit it rather than swapping under it
  if pgrep -f "$DEST/Contents/MacOS/Jarvis" >/dev/null 2>&1; then echo "JARVIS is running from $DEST. Quit it from its menu-bar menu, then run this again."; exit 2; fi
  [ "$(printf '%s\n%s\n' "$old.$oldb" "$new.$newb" | sort -V | tail -1)" = "$new.$newb" ] || { echo "The installed copy is NEWER than this build. Nothing was changed."; exit 3; }
fi
STAGE="$DEST_DIR/.JARVIS.app.installing"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
codesign --verify --strict --deep "$STAGE" || { rm -rf "$STAGE"; echo "The copy did not verify; nothing was changed."; exit 1; }
if [ -d "$DEST" ]; then mv "$DEST" "$DEST_DIR/.JARVIS.app.previous"; fi
mv "$STAGE" "$DEST"
rm -rf "$DEST_DIR/.JARVIS.app.previous"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "Installed $DEST"
# The staging copy has the same name and bundle id as the installed app: leaving it would put a second, confusing "JARVIS" in Finder, Spotlight and Launch Services.
rm -rf "$SRC" && rmdir build/package 2>/dev/null || true
echo "Removed the staging copy $SRC — /Applications/JARVIS.app is the only JARVIS application."
echo "Open it from Finder, Spotlight or the Applications folder. Your data stays in ~/Library/Application Support/JARVIS."
