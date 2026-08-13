#!/bin/sh
# Blocks tool use / new prompts once a Claude Code rate-limit window (5h or 7d)
# hits the configured threshold, until that window's reset time has passed.
# State is populated by statusline-command.sh from the official
# rate_limits.{five_hour,seven_day} fields Claude Code passes to the statusline.

input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# Tools that must stay usable even while blocked, so Claude can arrange or
# manage the autonomous resume (e.g. arming a wakeup for reset time).
case "$tool_name" in
  ScheduleWakeup|CronCreate|CronDelete|CronList) exit 0 ;;
esac

state_file="$HOME/.claude/rate-limit-state.json"
threshold_five_hour=95
threshold_seven_day=98

[ -f "$state_file" ] || exit 0

now=$(date +%s)
block_reason=""

check_window() {
  win_label="$1"
  win_key="$2"
  threshold="$3"
  used=$(jq -r ".${win_key}.used_percentage // empty" "$state_file" 2>/dev/null)
  resets_at=$(jq -r ".${win_key}.resets_at // empty" "$state_file" 2>/dev/null)

  [ -z "$used" ] && return
  [ -z "$resets_at" ] && return
  case "$resets_at" in ''|*[!0-9]*) return ;; esac

  # Window already rolled over since state was cached -> not blocked.
  [ "$now" -ge "$resets_at" ] && return

  over=$(awk -v u="$used" -v t="$threshold" 'BEGIN{print (u+0>=t+0)?"1":"0"}')
  if [ "$over" = "1" ]; then
    reset_human=$(date -d "@$resets_at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
    [ -z "$reset_human" ] && reset_human=$(date -r "$resets_at" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
    [ -z "$reset_human" ] && reset_human="timestamp $resets_at"
    block_reason="Claude Code usage limit reached: $win_label window at ${used}% (>= ${threshold}%). Resets at ${reset_human} (local time, unix ${resets_at}). Wait until then before continuing."
  fi
}

check_window "5-hour" "five_hour" "$threshold_five_hour"
[ -z "$block_reason" ] && check_window "7-day" "seven_day" "$threshold_seven_day"

[ -z "$block_reason" ] && exit 0

case "$event" in
  PreToolUse)
    jq -n --arg reason "$block_reason" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    ;;
  *)
    jq -n --arg reason "$block_reason" '{decision: "block", reason: $reason}'
    ;;
esac

exit 0
