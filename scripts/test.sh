#!/bin/zsh
# Runs unit tests with Command Line Tools only (no Xcode).
# The extra flags point at the CLT copy of the Swift Testing framework and its interop dylib.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
# --no-parallel: provider tests launch real child processes; running suites concurrently makes timing nondeterministic.
swift test --no-parallel \
  -Xswiftc -F$CLT/Frameworks -Xlinker -F$CLT/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/Frameworks \
  -Xlinker -rpath -Xlinker $CLT/usr/lib "$@"
# Test suites created by unit tests live in ~/Library/Preferences as UUID-named plists: remove only those (never the app's own dev.jarvis.Jarvis.plist).
rm -f "$HOME"/Library/Preferences/dev.jarvis.Jarvis.isolated.*.plist "$HOME"/Library/Preferences/jarvis-*-????????-????-????-????-????????????.plist "$HOME"/Library/Preferences/exp-pref-*.plist "$HOME"/Library/Preferences/ptt-*.plist 2>/dev/null || true
