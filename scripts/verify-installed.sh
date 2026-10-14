#!/bin/zsh
# Launches an INSTALLED (or staged) JARVIS.app the way Finder / Spotlight do — through LaunchServices, no arguments, no Terminal session — and checks what a person would see (V0.15, docs/APP_PACKAGING.md).
# Usage: scripts/verify-installed.sh [/Applications/JARVIS.app] [--crash]     (--crash also force-kills one copy and checks the relaunch)
# It does NOT click anything, change a setting, grant a permission or send a request; it launches, observes, opens it a second time, waits while idle, and asks it to quit normally.
# It refuses to run if a JARVIS is already running (it would otherwise quit YOUR session).
set -uo pipefail
cd "${0:A:h:h}"
APP="${1:-/Applications/JARVIS.app}"
BID="dev.jarvis.Jarvis"
PROBE=/tmp/jarvis-probe
[ -x "$PROBE" ] || swiftc -O scripts/installed-probe.swift -o "$PROBE" || { echo "cannot build the probe"; exit 1; }
fail=0
ok()   { print "PASS  $1"; }
bad()  { print "FAIL  $1"; fail=$((fail+1)); }
info() { print "INFO  $1"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
cpu_seconds() { ps -o cputime= -p "$1" 2>/dev/null | awk '{n=split($1,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print s}'; }

[ -d "$APP" ] || { echo "No app at $APP"; exit 1; }
[ -z "$($PROBE app $BID)" ] || { echo "A JARVIS is already running — quit it first (this check will not touch your session)."; exit 2; }
ok "no JARVIS was running before the check"

# 1. launch like Finder does
t0=$(now_ms)
open -a "$APP"
pid=""; for i in {1..300}; do l=$($PROBE app $BID | head -1); [ -n "$l" ] && { pid=${l%% *}; break; }; sleep 0.1; done
[ -n "$pid" ] && ok "JARVIS started (pid $pid)" || { bad "JARVIS did not start"; echo "INSTALLED CHECK FAILED"; exit 1; }
tproc=$(( $(now_ms) - t0 ))
menubar_ms=""
for i in {1..300}; do if [ -n "$($PROBE statusitem $BID)" ]; then menubar_ms=$(( $(now_ms) - t0 )); break; fi; sleep 0.1; done
[ -n "$menubar_ms" ] && ok "menu-bar item is on screen (${menubar_ms} ms after launch)" || bad "no menu-bar item appeared"
info "process visible after ${tproc} ms"

# 2. it is a normal application, not a terminal session
l=$($PROBE app $BID | head -1)
[[ "$l" == *"$APP"* ]] && ok "running from $APP" || bad "running from somewhere else: $l"
[[ "$l" == *"policy=1"* ]] && ok "menu-bar agent (no Dock icon)" || bad "activation policy: $l"
ppid=$(ps -o ppid= -p $pid | tr -d ' ')
[ "$ppid" = "1" ] && ok "parent is launchd (not a shell or a terminal)" || bad "parent pid is $ppid"
tty=$(ps -o tty= -p $pid | tr -d ' ')
[[ "$tty" == "??" || "$tty" == "-" ]] && ok "no controlling terminal" || bad "has a terminal: $tty"

# 3. opening it again shows the running copy; it never starts a second one
sleep 2
open -a "$APP"
sleep 2
count=$($PROBE app $BID | wc -l | tr -d ' ')
[ "$count" = "1" ] && ok "single instance (opening it again did not start a second copy)" || bad "$count copies are running"
$PROBE windows JARVIS | grep -q "onscreen=true" || $PROBE windows Jarvis | grep -q "onscreen=true" && ok "a JARVIS window is visible after opening it" || info "no HUD window was visible after the second open"

# 4. idle: lightweight, no heavy children
sleep 8
c1=$(cpu_seconds $pid); sleep 8; c2=$(cpu_seconds $pid)
rss=$(ps -o rss= -p $pid | tr -d ' ')
info "idle CPU over 8 s: $(awk -v a=$c1 -v b=$c2 'BEGIN{printf "%.2f", b-a}') s · RSS $((rss/1024)) MB"
awk -v a=$c1 -v b=$c2 'BEGIN{exit !((b-a) < 0.4)}' && ok "idle CPU under 5 % of one core" || bad "idle CPU is high"
kids=$(pgrep -P $pid | wc -l | tr -d ' ')
[ "$kids" = "0" ] && ok "no child process at idle (no model, provider, MCP server, Unity, browser)" || bad "$kids child process(es) at idle: $(ps -o comm= -p $(pgrep -P $pid | tr '\n' ',' | sed 's/,$//'))"
heavy=$(ps -axo comm= | grep -ciE 'jarvis_(local|stt|tts|vision|embed|sentinel)_worker|mlx|sandbox-exec' || true)
[ "$heavy" = "0" ] && ok "no helper or sandbox process anywhere" || bad "$heavy helper process(es) are running"

# 5. quit like ⌘Q
tq=$(now_ms)
$PROBE terminate $BID >/dev/null
gone=""; for i in {1..150}; do [ -z "$($PROBE app $BID)" ] && { gone=$(( $(now_ms) - tq )); break; }; sleep 0.1; done
[ -n "$gone" ] && ok "quit cleanly (${gone} ms)" || { bad "JARVIS did not quit"; kill -TERM $pid 2>/dev/null; }
sleep 1
[ -z "$(pgrep -P $pid 2>/dev/null)" ] && ok "no orphan child after quit" || bad "orphan child after quit"

# 6. HUD timing (developer flags open the HUD at launch; they are exempt from the single-instance rule) and crash recovery
wait_gone() { for i in {1..150}; do [ -z "$($PROBE app $BID)" ] && return 0; sleep 0.1; done; return 1; }
hud_ms() { # mode, predicate on "layer x y w h" lines
  local mode="$1" want="$2" t=$(now_ms) ms=""
  open -n -a "$APP" --args --open-$mode
  for i in {1..300}; do if $PROBE windows JARVIS | awk -v w="$want" '{ if (w=="compact" && $4==392 && $5==448) f=1; if (w=="full" && $4>=900) f=1 } END{exit !f}'; then ms=$(( $(now_ms) - t )); break; fi; sleep 0.1; done
  echo "$ms"
}
compact_ms=$(hud_ms compact compact); $PROBE terminate $BID >/dev/null; wait_gone
full_ms=$(hud_ms full full); $PROBE terminate $BID >/dev/null; wait_gone
[ -n "$compact_ms" ] && ok "Compact HUD (392 × 448) ready ${compact_ms} ms after launch" || bad "Compact HUD did not appear at 392 × 448"
[ -n "$full_ms" ] && ok "Full HUD ready ${full_ms} ms after launch" || bad "Full HUD did not appear"
if [[ "${2:-}" == "--crash" ]]; then
  open -a "$APP"; for i in {1..100}; do [ -n "$($PROBE app $BID)" ] && break; sleep 0.1; done
  cpid=$($PROBE app $BID | head -1 | cut -d' ' -f1); sleep 3; kill -9 $cpid; wait_gone && ok "force-killed copy is gone" || bad "force-killed copy is still there"
  sleep 1; open -a "$APP"; relaunched=""; for i in {1..100}; do [ -n "$($PROBE app $BID)" ] && { relaunched=1; break; }; sleep 0.1; done
  [ -n "$relaunched" ] && ok "relaunch after a crash works" || bad "relaunch after a crash failed"
  sleep 3
  rp=$($PROBE app $BID | head -1 | cut -d' ' -f1); [ -z "$(pgrep -P $rp 2>/dev/null)" ] && ok "no orphan or helper process after the crash recovery" || bad "child processes after crash recovery"
  $PROBE terminate $BID >/dev/null; wait_gone
fi

echo
echo "HUD timing: Compact ${compact_ms:-n/a} ms · Full ${full_ms:-n/a} ms"
echo "Cold launch: process ${tproc} ms · menu bar ${menubar_ms:-n/a} ms · idle RSS $((rss/1024)) MB · quit ${gone:-n/a} ms"
[ $fail -eq 0 ] && echo "INSTALLED CHECK PASSED" || { echo "INSTALLED CHECK FAILED ($fail)"; exit 1; }
