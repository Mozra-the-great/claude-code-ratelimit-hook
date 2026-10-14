#!/bin/sh
# Behaviour tests for hooks/rate-limit-waiter.sh.
#
# Contract (read from the script): it exits 0 immediately when nothing blocks (and
# removes a leftover lock) or when a live waiter already holds the lock for the same
# reset. Otherwise it writes ~/.claude/rate-limit-wait.lock {resets_at, pid}, sleeps
# (reset - now + 15 s buffer), removes the lock, prints a hint on stderr and exits 2
# (the harness reads exit 2 from an asyncRewake hook as "wake the model").
#
# `sleep` is replaced by a stub on PATH, so no test waits for a real reset: the stub
# records its argument and a copy of the lock file as it was while "sleeping".

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

WAITER=$ROOT/hooks/rate-limit-waiter.sh
LOCK=$HOME/.claude/rate-limit-wait.lock
BUFFER=15

STUB_DIR=$TEST_TMP/bin
SLEEP_LOG=$TEST_TMP/sleep.log
LOCK_SNAPSHOT=$TEST_TMP/lock.snapshot
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/sleep" <<STUB
#!/bin/sh
echo "\$*" >> "$SLEEP_LOG"
[ -f "$LOCK" ] && cp "$LOCK" "$LOCK_SNAPSHOT"
exit 0
STUB
chmod +x "$STUB_DIR/sleep"
PATH=$STUB_DIR:$PATH
export PATH

NOW=$(date +%s)
FUTURE=$((NOW + 3600))
FUTURE_2=$((NOW + 7200))
PAST=$((NOW - 3600))

# run_waiter -> sets RC, ERR, SLEEPS (the arguments the stub saw), SNAPSHOT (lock while sleeping)
run_waiter() {
  rm -f "$SLEEP_LOG" "$LOCK_SNAPSHOT"
  RUN_START=$(date +%s)
  "$TEST_SH" "$WAITER" > "$TEST_TMP/waiter.out" 2> "$TEST_TMP/waiter.err"
  RC=$?
  RUN_END=$(date +%s)
  ERR=$(cat "$TEST_TMP/waiter.err")
  SLEEPS=""
  [ -f "$SLEEP_LOG" ] && SLEEPS=$(cat "$SLEEP_LOG")
  SNAPSHOT=""
  [ -f "$LOCK_SNAPSHOT" ] && SNAPSHOT=$(cat "$LOCK_SNAPSHOT")
}

# assert_sleep_for <name> <resets_at>: the stub got exactly one argument, within the
# window the real clock allowed (the script samples `date` once at the start).
assert_sleep_for() {
  lo=$(($2 - RUN_END + BUFFER))
  hi=$(($2 - RUN_START + BUFFER))
  case "$SLEEPS" in
    *[!0-9]*|'')
      fail "$1: expected one numeric sleep argument, got '$SLEEPS'"
      ;;
    *)
      if [ "$SLEEPS" -ge "$lo" ] && [ "$SLEEPS" -le "$hi" ]; then
        pass
      else
        fail "$1: sleep $SLEEPS not in [$lo, $hi]"
      fi
      ;;
  esac
}

# ── nothing to wait for ──────────────────────────────────────────────────────
fresh_home
run_waiter
assert_eq "no state file: exit code" "0" "$RC"
assert_eq "no state file: no sleep" "" "$SLEEPS"
assert_no_file "no state file: no lock" "$LOCK"

write_state 10 "$FUTURE" 20 "$FUTURE_2"
run_waiter
assert_eq "below threshold: exit code" "0" "$RC"
assert_eq "below threshold: no sleep" "" "$SLEEPS"
assert_no_file "below threshold: no lock" "$LOCK"

write_state 99 "$PAST" 99 "$PAST"
run_waiter
assert_eq "over threshold but already reset: exit code" "0" "$RC"
assert_eq "over threshold but already reset: no sleep" "" "$SLEEPS"

echo 'not json' > "$HOME/.claude/rate-limit-state.json"
run_waiter
assert_eq "malformed state: exit code" "0" "$RC"
assert_eq "malformed state: no sleep" "" "$SLEEPS"

write_state 99 soon 99 12abc
run_waiter
assert_eq "malformed resets_at: exit code" "0" "$RC"
assert_eq "malformed resets_at: no sleep" "" "$SLEEPS"

# a leftover lock is cleaned up once nothing blocks any more
write_state 10 "$FUTURE" 10 "$FUTURE_2"
echo '{"resets_at": 1, "pid": 1}' > "$LOCK"
run_waiter
assert_eq "stale lock, nothing blocking: exit code" "0" "$RC"
assert_no_file "stale lock, nothing blocking: lock removed" "$LOCK"

# ── 5-hour window blocks: sleep until the reset, then wake the model ─────────
write_state 95 "$FUTURE" 10 "$FUTURE_2"
run_waiter
assert_eq "5-hour block: exit code 2 (rewake)" "2" "$RC"
assert_sleep_for "5-hour block" "$FUTURE"
assert_contains "5-hour block: stderr names the window" "$ERR" "Rate limit window '5-hour' has reset"
assert_contains "5-hour block: stderr tells the model to resume" "$ERR" "resume the paused task"
assert_eq "5-hour block: lock held while sleeping (resets_at)" "$FUTURE" \
  "$(printf '%s' "$SNAPSHOT" | jq -r '.resets_at // empty')"
assert_eq "5-hour block: lock holds the waiter pid" "number" \
  "$(printf '%s' "$SNAPSHOT" | jq -r '.pid | type')"
assert_no_file "5-hour block: lock removed after the wait" "$LOCK"

# ── 7-day window blocks ──────────────────────────────────────────────────────
write_state 10 "$FUTURE" 98 "$FUTURE_2"
run_waiter
assert_eq "7-day block: exit code 2" "2" "$RC"
assert_sleep_for "7-day block" "$FUTURE_2"
assert_contains "7-day block: stderr names the window" "$ERR" "Rate limit window '7-day' has reset"

# threshold boundaries are the same as the guard's (95 / 98)
write_state 94 "$FUTURE" 97 "$FUTURE_2"
run_waiter
assert_eq "just under both thresholds: exit code" "0" "$RC"
assert_eq "just under both thresholds: no sleep" "" "$SLEEPS"

# ── both blocking: the soonest reset wins ────────────────────────────────────
write_state 99 "$FUTURE_2" 99 "$FUTURE"
run_waiter
assert_eq "both blocking: exit code 2" "2" "$RC"
assert_sleep_for "both blocking: soonest reset (7-day here)" "$FUTURE"
assert_contains "both blocking: soonest window is named" "$ERR" "'7-day'"

write_state 99 "$FUTURE" 99 "$FUTURE_2"
run_waiter
assert_sleep_for "both blocking: soonest reset (5-hour here)" "$FUTURE"
assert_contains "both blocking: soonest window is named" "$ERR" "'5-hour'"

# an over-threshold window that has already reset is not a target
write_state 99 "$PAST" 99 "$FUTURE_2"
run_waiter
assert_sleep_for "expired 5-hour is skipped" "$FUTURE_2"
assert_contains "expired 5-hour is skipped: 7-day named" "$ERR" "'7-day'"

# ── lock dedup ───────────────────────────────────────────────────────────────
write_state 99 "$FUTURE" 10 "$FUTURE_2"

# live holder (this test shell) on the same reset: no second sleeper
jq -n --argjson r "$FUTURE" --argjson p "$$" '{resets_at: $r, pid: $p}' > "$LOCK"
run_waiter
assert_eq "live lock, same reset: exit code 0" "0" "$RC"
assert_eq "live lock, same reset: no second sleeper" "" "$SLEEPS"
assert_eq "live lock, same reset: stderr silent" "" "$ERR"
assert_file "live lock, same reset: lock kept" "$LOCK"

# holder is gone (dead pid): take over
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid"
jq -n --argjson r "$FUTURE" --argjson p "$dead_pid" '{resets_at: $r, pid: $p}' > "$LOCK"
run_waiter
assert_eq "dead lock holder: exit code 2" "2" "$RC"
assert_sleep_for "dead lock holder: waiter takes over" "$FUTURE"

# live holder, but for a different reset: this reset still needs a waiter
jq -n --argjson r "$FUTURE_2" --argjson p "$$" '{resets_at: $r, pid: $p}' > "$LOCK"
run_waiter
assert_eq "live lock, other reset: exit code 2" "2" "$RC"
assert_sleep_for "live lock, other reset: waiter starts" "$FUTURE"

# lock without a pid is not a live holder
jq -n --argjson r "$FUTURE" '{resets_at: $r}' > "$LOCK"
run_waiter
assert_eq "lock without pid: exit code 2" "2" "$RC"

# unparsable lock is not a live holder either
echo 'garbage' > "$LOCK"
run_waiter
assert_eq "garbage lock: exit code 2" "2" "$RC"
assert_sleep_for "garbage lock: waiter starts" "$FUTURE"

# ── the waiter never rewrites the state file ─────────────────────────────────
write_state 99 "$FUTURE" 10 "$FUTURE_2"
before=$(cat "$HOME/.claude/rate-limit-state.json")
rm -f "$LOCK"
run_waiter
assert_eq "state file untouched" "$before" "$(cat "$HOME/.claude/rate-limit-state.json")"

finish "test_waiter"
