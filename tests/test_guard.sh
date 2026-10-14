#!/bin/sh
# Behaviour tests for hooks/rate-limit-guard.sh.
#
# Contract (read from the script): the guard ALWAYS exits 0. "Blocked" is signalled
# on stdout as JSON, in the shape the event expects:
#   PreToolUse        {hookSpecificOutput:{hookEventName:"PreToolUse",
#                      permissionDecision:"deny", permissionDecisionReason:<reason>}}
#   anything else     {decision:"block", reason:<reason>}      (UserPromptSubmit)
# "Not blocked" is exit 0 with empty stdout. Thresholds: five_hour 95, seven_day 98.

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

GUARD=$ROOT/hooks/rate-limit-guard.sh
NOW=$(date +%s)
FUTURE=$((NOW + 3600))
FUTURE_2=$((NOW + 7200))
PAST=$((NOW - 3600))

# run_guard <event> <tool>  -> sets OUT and RC
run_guard() {
  payload=$(jq -n --arg e "$1" --arg t "$2" \
    '{hook_event_name: $e} + (if $t == "" then {} else {tool_name: $t} end)')
  OUT=$(printf '%s' "$payload" | "$TEST_SH" "$GUARD" 2>/dev/null)
  RC=$?
}

# assert_allowed <name> [event] [tool]
assert_allowed() {
  run_guard "${2:-PreToolUse}" "${3:-Bash}"
  assert_eq "$1 (exit code)" "0" "$RC"
  assert_eq "$1 (no output)" "" "$OUT"
}

# assert_denied <name> <reason fragment> [event] [tool]   (PreToolUse deny shape)
assert_denied() {
  run_guard "${3:-PreToolUse}" "${4:-Bash}"
  assert_eq "$1 (exit code)" "0" "$RC"
  assert_eq "$1 (decision)" "deny" \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"')"
  assert_eq "$1 (event name)" "PreToolUse" \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // "none"')"
  reason=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  assert_contains "$1 (reason)" "$reason" "$2"
}

# ── no data: fail open ───────────────────────────────────────────────────────
fresh_home
assert_allowed "no state file"

echo 'not json at all' > "$HOME/.claude/rate-limit-state.json"
assert_allowed "malformed state file"

echo '{}' > "$HOME/.claude/rate-limit-state.json"
assert_allowed "empty state object"

write_state null 0 null 0
assert_allowed "both windows null"

# ── below threshold ──────────────────────────────────────────────────────────
write_state 10 "$FUTURE" 20 "$FUTURE_2"
assert_allowed "both windows below threshold"

write_state 94 "$FUTURE" 97 "$FUTURE_2"
assert_allowed "one point under both thresholds"

write_state 94.99 "$FUTURE" 97.99 "$FUTURE_2"
assert_allowed "fractional just under both thresholds"

# ── five_hour ────────────────────────────────────────────────────────────────
write_state 95 "$FUTURE" 10 "$FUTURE_2"
assert_denied "five_hour at 95, future reset" "5-hour window at 95%"
assert_contains "reason names the threshold" "$reason" ">= 95%"
assert_contains "reason carries the unix reset time" "$reason" "unix $FUTURE"
assert_contains "reason tells the model to wait" "$reason" "Wait until then"

write_state 100 "$FUTURE" 10 "$FUTURE_2"
assert_denied "five_hour at 100" "5-hour window at 100%"

write_state 95.0 "$FUTURE" 10 "$FUTURE_2"
assert_denied "five_hour at 95.0 (float)" "5-hour window"

write_state 99 "$PAST" 10 "$FUTURE_2"
assert_allowed "five_hour over threshold but reset already passed"

write_state 99 "$NOW" 10 "$FUTURE_2"
assert_allowed "five_hour reset exactly now counts as rolled over"

# ── seven_day ────────────────────────────────────────────────────────────────
write_state 10 "$FUTURE" 98 "$FUTURE_2"
assert_denied "seven_day at 98, future reset" "7-day window at 98%"
assert_contains "reason names the 7-day threshold" "$reason" ">= 98%"
assert_contains "reason carries the 7-day reset time" "$reason" "unix $FUTURE_2"

write_state 10 "$FUTURE" 97.9 "$FUTURE_2"
assert_allowed "seven_day at 97.9"

write_state 10 "$FUTURE" 99 "$PAST"
assert_allowed "seven_day over threshold but reset already passed"

# 95% is only a limit for the 5-hour window, not for the 7-day one
write_state 10 "$FUTURE" 95 "$FUTURE_2"
assert_allowed "seven_day at 95 is below its own threshold"

# ── both windows ─────────────────────────────────────────────────────────────
write_state 96 "$FUTURE" 99 "$FUTURE_2"
assert_denied "both over: the 5-hour window is reported" "5-hour window at 96%"
assert_not_contains "both over: only one reason" "$reason" "7-day"

write_state 96 "$PAST" 99 "$FUTURE_2"
assert_denied "5-hour rolled over, 7-day still blocks" "7-day window at 99%"

# ── whitelisted tools stay usable while blocked ──────────────────────────────
write_state 99 "$FUTURE" 99 "$FUTURE_2"
for tool in ScheduleWakeup CronCreate CronDelete CronList; do
  assert_allowed "whitelisted tool $tool while blocked" PreToolUse "$tool"
done
assert_denied "Bash is blocked" "usage limit reached" PreToolUse Bash
assert_denied "Edit is blocked" "usage limit reached" PreToolUse Edit
# the whitelist is an exact match, not a prefix match
assert_denied "CronCreateExtra is not whitelisted" "usage limit reached" PreToolUse CronCreateExtra
assert_denied "event without a tool name is blocked" "usage limit reached" PreToolUse ""

# ── event shapes ─────────────────────────────────────────────────────────────
write_state 99 "$FUTURE" 10 "$FUTURE_2"
run_guard UserPromptSubmit ""
assert_eq "UserPromptSubmit exit code" "0" "$RC"
assert_eq "UserPromptSubmit decision" "block" "$(printf '%s' "$OUT" | jq -r '.decision // "none"')"
assert_contains "UserPromptSubmit reason" "$(printf '%s' "$OUT" | jq -r '.reason // ""')" "5-hour window at 99%"
assert_eq "UserPromptSubmit has no PreToolUse envelope" "null" \
  "$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput')"

# ── malformed fields are ignored, never an error ─────────────────────────────
NOW_MALFORMED=soon
write_state 99 "$NOW_MALFORMED" 10 "$FUTURE_2"
assert_allowed "non-numeric resets_at"

for bad in 12abc -5 1.5 ""; do
  jq -n --arg r "$bad" '{five_hour: {used_percentage: 99, resets_at: $r}, seven_day: null}' \
    > "$HOME/.claude/rate-limit-state.json"
  assert_allowed "resets_at '$bad' is ignored"
done

echo '{"five_hour": {"used_percentage": 99}, "seven_day": null}' > "$HOME/.claude/rate-limit-state.json"
assert_allowed "missing resets_at"

jq -n --argjson f "$FUTURE" '{five_hour: {resets_at: $f}, seven_day: null}' > "$HOME/.claude/rate-limit-state.json"
assert_allowed "missing used_percentage"

# a broken 5-hour entry must not hide a valid, blocking 7-day entry
jq -n --argjson f "$FUTURE_2" \
  '{five_hour: {used_percentage: 99, resets_at: "soon"}, seven_day: {used_percentage: 99, resets_at: $f}}' \
  > "$HOME/.claude/rate-limit-state.json"
assert_denied "malformed 5-hour does not mask a blocking 7-day" "7-day window at 99%"

# ── the guard does not modify state ──────────────────────────────────────────
write_state 99 "$FUTURE" 10 "$FUTURE_2"
before=$(cat "$HOME/.claude/rate-limit-state.json")
run_guard PreToolUse Bash
assert_eq "state file untouched" "$before" "$(cat "$HOME/.claude/rate-limit-state.json")"
assert_no_file "no lock file created" "$HOME/.claude/rate-limit-wait.lock"

finish "test_guard"
