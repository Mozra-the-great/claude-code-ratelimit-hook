#!/bin/sh
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

has_rl=$(echo "$input" | jq -r 'has("rate_limits")')
if [ "$has_rl" = "true" ]; then
  echo "$input" | jq --argjson now "$(date +%s)" \
    '{five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day, updated_at: $now}' \
    > "$HOME/.claude/rate-limit-state.json" 2>/dev/null
fi
rl5=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl7=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

parts=""

[ -n "$cwd" ] && parts="$cwd"

[ -n "$model" ] && {
  if [ -n "$parts" ]; then parts="$parts | $model"; else parts="$model"; fi
}

[ -n "$used" ] && {
  ctx=$(printf "ctx: %.0f%%" "$used")
  if [ -n "$parts" ]; then parts="$parts | $ctx"; else parts="$ctx"; fi
}

[ -n "$rl5" ] && [ -n "$rl7" ] && {
  rl=$(printf "5h:%.0f%% 7d:%.0f%%" "$rl5" "$rl7")
  if [ -n "$parts" ]; then parts="$parts | $rl"; else parts="$rl"; fi
}

printf "%s" "$parts"
