#!/bin/sh
# Install the rate-limit hook scripts into ~/.claude. Idempotent.
#
# Usage: ./install.sh [--copy]
#
# Default is to symlink, so `git pull` in this checkout updates the installed
# scripts. --copy installs real files instead.
#
# Run as the user Claude Code runs as. Does not need root.

set -eu

MODE=symlink
case "${1:-}" in
  --copy) MODE=copy ;;
  "") ;;
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
esac

# CDPATH must be empty, otherwise `cd` may print and jump somewhere else.
# Assigned on its own line rather than as a `CDPATH= cd ...` prefix, because
# SC1007 flags that prefix form as a likely typo.
CDPATH=''
src_dir=$(cd -- "$(dirname -- "$0")" && pwd)
dest_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "install.sh: awk is required" >&2; exit 1; }

mkdir -p "$dest_dir"

# Deliberately installed flat in ~/.claude, not in ~/.claude/hooks/ - the
# settings.json snippet references `bash ~/.claude/<name>.sh`.
for name in statusline-command.sh rate-limit-guard.sh rate-limit-waiter.sh; do
  src=$src_dir/hooks/$name
  dest=$dest_dir/$name

  # Never silently clobber a real file the user already had there.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    backup=$dest.bak-$(date +%Y%m%d-%H%M%S)
    mv "$dest" "$backup"
    echo "install.sh: backed up existing $name to $(basename "$backup")"
  fi

  rm -f "$dest"
  if [ "$MODE" = copy ]; then
    cp "$src" "$dest"
  else
    ln -s "$src" "$dest"
  fi
  chmod +x "$src"
done

echo "install.sh: installed 3 scripts into $dest_dir ($MODE)"
cat <<EOF

Now merge settings.snippet.json into $dest_dir/settings.json. If you have jq and
no existing statusLine or hooks entries you want to keep:

  jq -s '.[0] * .[1]' $dest_dir/settings.json $src_dir/settings.snippet.json \\
    > $dest_dir/settings.json.new && mv $dest_dir/settings.json.new $dest_dir/settings.json

Restart Claude Code, then confirm the statusline is feeding the cache:

  cat $dest_dir/rate-limit-state.json
EOF
