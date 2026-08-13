#!/bin/sh
# Remove the rate-limit hook scripts from ~/.claude.
#
# Does not touch settings.json - remove the statusLine and hooks entries by hand,
# otherwise Claude Code will report a missing hook command on every tool call.

set -eu

dest_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

for name in statusline-command.sh rate-limit-guard.sh rate-limit-waiter.sh; do
  rm -f "$dest_dir/$name"
done
rm -f "$dest_dir/rate-limit-state.json" "$dest_dir/rate-limit-wait.lock"

cat <<EOF
Removed the scripts and state from $dest_dir.

Still to do by hand: delete the "statusLine" entry and the two rate-limit hook
entries under "hooks" in $dest_dir/settings.json.
EOF
