#!/bin/sh
# Companion to rate-limit-guard.sh. Registered as an async + asyncRewake hook:
# runs in the background and, if a rate-limit window is currently over its
# threshold, sleeps until that window's reset time and then exits 2 - which
# the Claude Code harness delivers back as a system-reminder that wakes the
# model, letting it autonomously resume the paused task.
#
# Dedup via a lock file (resets_at + pid) so repeated PreToolUse/UserPromptSubmit
# firings while blocked don't spawn overlapping sleepers.

state_file="$HOME/.claude/rate-limit-state.json"
lock_file="$HOME/.claude/rate-limit-wait.lock"
threshold_five_hour=95
threshold_seven_day=98
buffer_seconds=15

[ -f "$state_file" ] || exit 0

now=$(date +%s)
target_resets_at=""
target_label=""

consider_window() {
  win_label="$1"
  win_key="$2"
  threshold="$3"
  used=$(jq -r ".${win_key}.used_percentage // empty" "$state_file" 2>/dev/null)
  resets_at=$(jq -r ".${win_key}.resets_at // empty" "$state_file" 2>/dev/null)

  [ -z "$used" ] && return
  [ -z "$resets_at" ] && return
  case "$resets_at" in ''|*[!0-9]*) return ;; esac
  [ "$now" -ge "$resets_at" ] && return

  over=$(awk -v u="$used" -v t="$threshold" 'BEGIN{print (u+0>=t+0)?"1":"0"}')
  [ "$over" != "1" ] && return

  # Track the SOONEST reset among currently-blocking windows.
  if [ -z "$target_resets_at" ] || [ "$resets_at" -lt "$target_resets_at" ]; then
    target_resets_at="$resets_at"
    target_label="$win_label"
  fi
}

consider_window "5-hour" "five_hour" "$threshold_five_hour"
consider_window "7-day" "seven_day" "$threshold_seven_day"

is_locked_and_live() {
  [ -f "$lock_file" ] || return 1
  locked_resets_at=$(jq -r '.resets_at // empty' "$lock_file" 2>/dev/null)
  locked_pid=$(jq -r '.pid // empty' "$lock_file" 2>/dev/null)
  [ -z "$locked_resets_at" ] && return 1
  [ "$locked_resets_at" != "$1" ] && return 1
  [ -z "$locked_pid" ] && return 1
  kill -0 "$locked_pid" 2>/dev/null
}

if [ -z "$target_resets_at" ]; then
  # Nothing blocking right now - clear any leftover lock and exit quietly.
  rm -f "$lock_file" 2>/dev/null
  exit 0
fi

if is_locked_and_live "$target_resets_at"; then
  # Already waiting on this exact reset - don't spawn a duplicate.
  exit 0
fi

jq -n --arg resets_at "$target_resets_at" --arg pid "$$" \
  '{resets_at: ($resets_at | tonumber), pid: ($pid | tonumber)}' > "$lock_file"

sleep_for=$(( target_resets_at - now + buffer_seconds ))
[ "$sleep_for" -lt 1 ] && sleep_for=1
sleep "$sleep_for"

rm -f "$lock_file" 2>/dev/null

reset_human=$(date -d "@$target_resets_at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
[ -z "$reset_human" ] && reset_human="timestamp $target_resets_at"

echo "Rate limit window '$target_label' has reset (was blocking until ${reset_human}). Re-check ~/.claude/rate-limit-state.json - if no window is over its threshold anymore, resume the paused task now without waiting for further user input." 1>&2
exit 2
