#!/bin/sh
# Behaviour tests for hooks/statusline-command.sh: it renders the statusline and,
# whenever the payload carries rate_limits, caches them for the guard and waiter in
# ~/.claude/rate-limit-state.json as {five_hour, seven_day, updated_at}.

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

STATUSLINE=$ROOT/hooks/statusline-command.sh
GUARD=$ROOT/hooks/rate-limit-guard.sh
STATE=$HOME/.claude/rate-limit-state.json
NOW=$(date +%s)
FUTURE=$((NOW + 3600))

# run_statusline <json payload> -> sets OUT, RC
run_statusline() {
  OUT=$(printf '%s' "$1" | "$TEST_SH" "$STATUSLINE" 2>/dev/null)
  RC=$?
}

# ── full payload: rendering and caching ──────────────────────────────────────
fresh_home
payload=$(jq -n --argjson f "$FUTURE" '{
  cwd: "/work/demo", model: {display_name: "Opus"},
  context_window: {used_percentage: 41.6},
  rate_limits: {five_hour: {used_percentage: 42.4, resets_at: $f},
                seven_day: {used_percentage: 7, resets_at: ($f + 1000)}}
}')
run_statusline "$payload"
assert_eq "full payload: exit code" "0" "$RC"
assert_eq "full payload: rendered line" "/work/demo | Opus | ctx: 42% | 5h:42% 7d:7%" "$OUT"
assert_file "full payload: state file written" "$STATE"
assert_eq "cached five_hour.used_percentage" "42.4" "$(jq -r '.five_hour.used_percentage' "$STATE")"
assert_eq "cached five_hour.resets_at" "$FUTURE" "$(jq -r '.five_hour.resets_at' "$STATE")"
assert_eq "cached seven_day.used_percentage" "7" "$(jq -r '.seven_day.used_percentage' "$STATE")"
assert_eq "cached seven_day.resets_at" "$((FUTURE + 1000))" "$(jq -r '.seven_day.resets_at' "$STATE")"
updated=$(jq -r '.updated_at' "$STATE")
if [ "$updated" -ge "$NOW" ] && [ "$updated" -le "$(date +%s)" ]; then
  pass
else
  fail "updated_at $updated is not the current time"
fi

# ── no rate_limits: render only, never touch the cache ───────────────────────
fresh_home
run_statusline '{"cwd": "/work/demo", "model": {"display_name": "Opus"}}'
assert_eq "no rate_limits: exit code" "0" "$RC"
assert_eq "no rate_limits: rendered line" "/work/demo | Opus" "$OUT"
assert_no_file "no rate_limits: state file not created" "$STATE"

# an older cache survives a payload without rate_limits
write_state 12 "$FUTURE" 13 "$FUTURE"
before=$(cat "$STATE")
run_statusline '{"cwd": "/work/demo"}'
assert_eq "no rate_limits: existing cache untouched" "$before" "$(cat "$STATE")"

# ── degenerate payloads render without failing ───────────────────────────────
run_statusline '{}'
assert_eq "empty object: exit code" "0" "$RC"
assert_eq "empty object: empty line" "" "$OUT"

run_statusline '{"workspace": {"current_dir": "/ws"}, "model": {"display_name": "Haiku"}}'
assert_eq "workspace.current_dir is the cwd fallback" "/ws | Haiku" "$OUT"

# ── statusline -> state -> guard: the whole chain ────────────────────────────
fresh_home
payload=$(jq -n --argjson f "$FUTURE" '{
  rate_limits: {five_hour: {used_percentage: 96, resets_at: $f},
                seven_day: {used_percentage: 5, resets_at: ($f + 1000)}}
}')
run_statusline "$payload"
assert_eq "chain: rendered rate limits" "5h:96% 7d:5%" "$OUT"
guard_out=$(printf '%s' '{"hook_event_name": "PreToolUse", "tool_name": "Bash"}' | "$TEST_SH" "$GUARD" 2>/dev/null)
assert_eq "chain: the guard blocks on the cached state" "deny" \
  "$(printf '%s' "$guard_out" | jq -r '.hookSpecificOutput.permissionDecision // "none"')"

payload=$(jq -n --argjson f "$FUTURE" '{
  rate_limits: {five_hour: {used_percentage: 20, resets_at: $f},
                seven_day: {used_percentage: 5, resets_at: ($f + 1000)}}
}')
run_statusline "$payload"
guard_out=$(printf '%s' '{"hook_event_name": "PreToolUse", "tool_name": "Bash"}' | "$TEST_SH" "$GUARD" 2>/dev/null)
assert_eq "chain: the guard releases once the cache drops" "" "$guard_out"

finish "test_statusline"
