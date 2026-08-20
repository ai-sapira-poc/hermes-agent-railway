#!/usr/bin/env bash
# Unit test for the two pieces of entrypoint.sh that are easy to get wrong and
# impossible to notice when they break: the shutdown fan-out (term_handler) and the
# daily-window arithmetic (_seconds_until_hour). Both are EXTRACTED FROM THE REAL
# FILE rather than copied, so this test fails if entrypoint.sh drifts away from it.
#
# Run: bash tests/test_entrypoint_drain.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"
fails=0

check() {  # check <name> <condition-result>
  if [ "$2" = "0" ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; fails=$(( fails + 1 )); fi
}

# Pull the two functions out of the real entrypoint and into this shell.
eval "$(sed -n '/^_seconds_until_hour()/,/^}/p' "$ENTRYPOINT")"
eval "$(sed -n '/^term_handler()/,/^}/p' "$ENTRYPOINT")"

echo "_seconds_until_hour"
[ "$(type -t _seconds_until_hour)" = "function" ]; check "extracted from entrypoint.sh" $?
now_secs=$(( 10#$(date -u +%H) * 3600 + 10#$(date -u +%M) * 60 + 10#$(date -u +%S) ))
for h in 0 4 9 23; do
  s="$(_seconds_until_hour "$h")"
  expect=$(( h * 3600 - now_secs ))
  if [ "$expect" -le 0 ]; then expect=$(( expect + 86400 )); fi
  [ "$s" = "$expect" ]; check "hour $h -> ${s}s" $?
  { [ "$s" -gt 0 ] && [ "$s" -le 86400 ]; }; check "hour $h lands inside (0, 24h]" $?
done
# A zero-padded clock hour (08, 09) must not be read as invalid octal.
( _seconds_until_hour 9 >/dev/null 2>&1 ); check "no octal parse error on the current hour" $?

echo
echo "term_handler — gateways that stop when asked"
tmp="$(mktemp -d)"
bash -c 'trap "echo term >> '"$tmp"'/a.log; exit 0" TERM; while true; do sleep 0.1; done' &
g1=$!
bash -c 'trap "echo term >> '"$tmp"'/b.log; exit 0" TERM; while true; do sleep 0.1; done' &
g2=$!
sleep 0.3
GATEWAY_PIDS=("$g1" "$g2"); GUARD_PID=""; MAIN_PID=""; HERMES_DRAIN_TIMEOUT=5
out="$( term_handler 2>&1 )"; rc=$?
[ "$rc" = "0" ]; check "handler exits 0" $?
[ -f "$tmp/a.log" ] && [ -f "$tmp/b.log" ]; check "every gateway received SIGTERM" $?
grep -q "exited cleanly" <<<"$out"; check "reports a clean drain" $?
! kill -0 "$g1" 2>/dev/null && ! kill -0 "$g2" 2>/dev/null; check "no gateway left running" $?

echo
echo "term_handler — a gateway that will not stop"
bash -c 'trap "" TERM; while true; do sleep 0.1; done' &
stubborn=$!
sleep 0.3
GATEWAY_PIDS=("$stubborn"); GUARD_PID=""; MAIN_PID=""; HERMES_DRAIN_TIMEOUT=2
start=$(date +%s)
out="$( term_handler 2>&1 )"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" = "0" ]; check "handler still exits 0 (never blocks the stop)" $?
grep -q "still busy" <<<"$out"; check "reports the undrained gateway" $?
{ [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 5 ]; }; check "waits the budget, not longer (${elapsed}s)" $?
kill -9 "$stubborn" 2>/dev/null; wait "$stubborn" 2>/dev/null

echo
echo "term_handler — guard is killed first"
bash -c 'while true; do sleep 0.1; done' &
guard=$!
sleep 0.2
GATEWAY_PIDS=(); GUARD_PID="$guard"; MAIN_PID=""; HERMES_DRAIN_TIMEOUT=2
( term_handler ) >/dev/null 2>&1
sleep 0.3
! kill -0 "$guard" 2>/dev/null; check "pin-drift guard stopped (no bump PR from a dying box)" $?
kill -9 "$guard" 2>/dev/null; wait "$guard" 2>/dev/null

echo
echo "no gateways at all (headless box)"
GATEWAY_PIDS=(); GUARD_PID=""; MAIN_PID=""; HERMES_DRAIN_TIMEOUT=2
start=$(date +%s)
( term_handler ) >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" = "0" ]; check "empty gateway list is not an error" $?
[ "$elapsed" -le 1 ]; check "returns immediately, no idle wait" $?

rm -rf "$tmp"
echo
if [ "$fails" -gt 0 ]; then echo "FAILED ($fails)"; exit 1; fi
echo "ALL ENTRYPOINT DRAIN TESTS PASSED"
