#!/bin/zsh
# Canonical V0.1 automated verification: unit tests → bundle → plist/permission audit → smoke test → idle resources.
# Prints PASS / FAIL / SKIP lines and exits non-zero on any FAIL. Does NOT replace the user's manual test.
cd "$(dirname "$0")/.."
fails=0
pass() { print "PASS  $1"; }
fail() { print "FAIL  $1"; fails=$((fails+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi }

print "== Unit tests"
out=$(scripts/test.sh 2>&1); echo "$out" | grep -E "Test run with" || true
echo "$out" | grep -q "passed after" && ! echo "$out" | grep -q "✘" && pass "unit tests" || fail "unit tests"

print "== Bundle"
scripts/build_app.sh release >/dev/null 2>&1 && pass "build_app.sh release" || { fail "build_app.sh release"; exit 1; }
APP=build/Jarvis.app
check "Info.plist lints" plutil -lint $APP/Contents/Info.plist
check "LSUIElement = true (menu bar agent)" test "$(plutil -extract LSUIElement raw $APP/Contents/Info.plist)" = "true"
check "CFBundleExecutable exists" test -x "$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw $APP/Contents/Info.plist)"
check "signature valid (strict, deep)" codesign --verify --strict --deep $APP
check "arm64 binary" sh -c "lipo -archs $APP/Contents/MacOS/Jarvis | grep -q arm64"

print "== Permission audit"
! plutil -p $APP/Contents/Info.plist | grep -qi "UsageDescription" && pass "no NS*UsageDescription keys" || fail "no NS*UsageDescription keys"
[ -z "$(codesign -d --entitlements - $APP 2>/dev/null | grep -v -E '^Executable=')" ] && pass "no entitlements" || fail "no entitlements"
! grep -rEl "AVCaptureDevice|CGRequestScreenCapture|CGPreflightScreenCapture|AXIsProcessTrusted|NSAppleScript|SFSpeechRecognizer|addGlobalMonitorForEvents|CGEventTapCreate|RegisterEventHotKey|IOHIDManager|CNContactStore|CLLocationManager|UNUserNotificationCenter" Sources \
  && pass "no permission-gated API usage in sources" || fail "permission-gated API usage found in sources"

print "== Smoke test (real window manager, store, status item)"
log=$(mktemp)
$APP/Contents/MacOS/Jarvis --smoke-test >$log 2>&1; rc=$?
grep -E "^(FAIL|SKIP)" $log
print "   $(grep -c '^PASS' $log) PASS, $(grep -c '^FAIL' $log) FAIL, $(grep -c '^SKIP' $log) SKIP"
[ $rc -eq 0 ] && pass "smoke test exit code 0" || fail "smoke test exit code $rc"
! grep -v -E "^(PASS|FAIL|SKIP|SMOKE)" $log | grep -qi -E "error|fault|unable to|constraint|warning" \
  && pass "no error/warning output from app (stdout+stderr)" || { fail "unexpected error/warning output"; grep -i -E "error|fault|unable|constraint|warning" $log | head; }

print "== Idle resource check (HUDs closed, state idle, 8s window)"
pkill -x Jarvis 2>/dev/null; sleep 1
open -n $APP --args --state idle
sleep 4
pid=$(pgrep -x Jarvis)
cpu() { ps -o cputime= -p $pid | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
a=$(cpu); sleep 8; b=$(cpu)
used=$(echo "$b - $a" | bc)
print "   CPU seconds used in 8s: $used   RSS: $(ps -o rss= -p $pid | awk '{printf "%.0f MB", $1/1024}')"
[ "$(echo "$used < 0.4" | bc)" = "1" ] && pass "idle CPU < 5% of one core" || fail "idle CPU too high ($used s / 8 s)"
pkill -x Jarvis 2>/dev/null

print
(( fails == 0 )) && print "VERIFY PASSED" || print "VERIFY FAILED ($fails)"
exit $fails
