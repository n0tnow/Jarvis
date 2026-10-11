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
