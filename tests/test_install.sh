#!/bin/sh
# Smoke tests for install.sh / uninstall.sh in a throw-away HOME / CLAUDE_CONFIG_DIR.
#
# install.sh: symlinks (default) or copies (--copy) the three scripts flat into the
# config dir, backs up a differing real file to <name>.bak-<timestamp> but never
# piles up backups when re-running --copy over its own copies, prints the jq merge
# one-liner for settings.json, and rejects unknown arguments with exit 2.
# uninstall.sh: removes the scripts, state and lock; leaves settings.json alone.

# shellcheck source=/dev/null  # tests/lib.sh, linted on its own
. "$(dirname -- "$0")/lib.sh"

INSTALL=$ROOT/install.sh
UNINSTALL=$ROOT/uninstall.sh
SCRIPTS="statusline-command.sh rate-limit-guard.sh rate-limit-waiter.sh"
DEST=$HOME/.claude

# Where `ln -s` cannot create real symlinks (Git Bash on Windows silently copies),
# the symlink assertions are replaced by "installed and identical" checks. On Linux
# and macOS - and so in CI - the symlinks are asserted for real.
if ln -s "$ROOT/install.sh" "$TEST_TMP/probe-link" 2>/dev/null && [ -L "$TEST_TMP/probe-link" ]; then
  SYMLINKS=1
else
  SYMLINKS=0
  echo "note: ln -s makes no symlinks here; symlink assertions are relaxed" >&2
fi

# count_backups -> number of *.bak-* files in the config dir
count_backups() {
  n=0
  for f in "$DEST"/*.bak-*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

# ── default mode: symlinks ───────────────────────────────────────────────────
fresh_home
OUT=$("$TEST_SH" "$INSTALL" 2>&1)
RC=$?
assert_eq "install: exit code" "0" "$RC"
assert_contains "install: summary line" "$OUT" "installed 3 scripts into $DEST (symlink)"
for s in $SCRIPTS; do
  if [ "$SYMLINKS" = 1 ]; then
    if [ -L "$DEST/$s" ]; then pass; else fail "install: $s is not a symlink"; fi
    assert_eq "install: $s points into the checkout" "$ROOT/hooks/$s" "$(readlink "$DEST/$s")"
  else
    if cmp -s "$ROOT/hooks/$s" "$DEST/$s"; then pass; else fail "install: $s differs from the source"; fi
  fi
done
assert_no_file "install: no settings.json created behind the back of the user" "$DEST/settings.json"

# the installed guard runs (and fails open without a state file)
OUT=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | "$TEST_SH" "$DEST/rate-limit-guard.sh" 2>&1)
assert_eq "install: installed guard runs" "" "$OUT"

# idempotent
"$TEST_SH" "$INSTALL" > /dev/null 2>&1
assert_eq "re-install (symlink): exit code" "0" "$?"
assert_eq "re-install (symlink): no backups" "0" "$(count_backups)"

# ── --copy mode ──────────────────────────────────────────────────────────────
fresh_home
OUT=$("$TEST_SH" "$INSTALL" --copy 2>&1)
assert_eq "install --copy: exit code" "0" "$?"
assert_contains "install --copy: summary line" "$OUT" "(copy)"
for s in $SCRIPTS; do
  if [ -f "$DEST/$s" ] && [ ! -L "$DEST/$s" ]; then pass; else fail "install --copy: $s is not a real file"; fi
  if cmp -s "$ROOT/hooks/$s" "$DEST/$s"; then pass; else fail "install --copy: $s differs from the source"; fi
  if [ -x "$DEST/$s" ]; then pass; else fail "install --copy: $s is not executable"; fi
done

# re-running --copy over its own identical copies must not leave .bak files (latest fix)
"$TEST_SH" "$INSTALL" --copy > /dev/null 2>&1
"$TEST_SH" "$INSTALL" --copy > /dev/null 2>&1
assert_eq "re-run --copy: no .bak per re-run" "0" "$(count_backups)"

# a locally modified real file IS backed up, with its content, and replaced
echo '# local edit' >> "$DEST/rate-limit-guard.sh"
OUT=$("$TEST_SH" "$INSTALL" --copy 2>&1)
assert_eq "modified copy: exactly one backup" "1" "$(count_backups)"
assert_contains "modified copy: backup is announced" "$OUT" "backed up existing rate-limit-guard.sh"
for b in "$DEST"/rate-limit-guard.sh.bak-*; do
  assert_contains "modified copy: backup keeps the edit" "$(cat "$b")" "# local edit"
done
if cmp -s "$ROOT/hooks/rate-limit-guard.sh" "$DEST/rate-limit-guard.sh"; then pass; else fail "modified copy: not restored"; fi

# a foreign real file (not ours) is never clobbered silently
fresh_home
echo 'echo mine' > "$DEST/statusline-command.sh"
"$TEST_SH" "$INSTALL" > /dev/null 2>&1
assert_eq "foreign file: backed up" "1" "$(count_backups)"
for b in "$DEST"/statusline-command.sh.bak-*; do
  assert_eq "foreign file: backup content" "echo mine" "$(cat "$b")"
done
if cmp -s "$ROOT/hooks/statusline-command.sh" "$DEST/statusline-command.sh"; then pass; else fail "foreign file: not replaced by the script"; fi

# switching copy -> symlink -> copy does not leave backups of our own files
fresh_home
"$TEST_SH" "$INSTALL" --copy > /dev/null 2>&1
"$TEST_SH" "$INSTALL" > /dev/null 2>&1
"$TEST_SH" "$INSTALL" --copy > /dev/null 2>&1
assert_eq "switching modes: no backups" "0" "$(count_backups)"

# ── CLAUDE_CONFIG_DIR is honoured ────────────────────────────────────────────
fresh_home
CUSTOM=$TEST_TMP/custom-config
CLAUDE_CONFIG_DIR=$CUSTOM "$TEST_SH" "$INSTALL" --copy > /dev/null 2>&1
for s in $SCRIPTS; do
  assert_file "CLAUDE_CONFIG_DIR: $s installed there" "$CUSTOM/$s"
  assert_no_file "CLAUDE_CONFIG_DIR: $s not in ~/.claude" "$DEST/$s"
done
CLAUDE_CONFIG_DIR=$CUSTOM "$TEST_SH" "$UNINSTALL" > /dev/null 2>&1
for s in $SCRIPTS; do
  assert_no_file "CLAUDE_CONFIG_DIR: $s uninstalled from there" "$CUSTOM/$s"
done

# ── argument handling ────────────────────────────────────────────────────────
fresh_home
OUT=$("$TEST_SH" "$INSTALL" --bogus 2>&1)
assert_eq "unknown argument: exit code 2" "2" "$?"
assert_contains "unknown argument: message" "$OUT" "unknown argument: --bogus"
assert_no_file "unknown argument: nothing installed" "$DEST/rate-limit-guard.sh"

OUT=$("$TEST_SH" "$INSTALL" --help 2>&1)
assert_eq "--help: exit code 0" "0" "$?"
assert_contains "--help: usage" "$OUT" "Usage: ./install.sh [--copy]"
assert_no_file "--help: nothing installed" "$DEST/rate-limit-guard.sh"

# ── settings merge: run the one-liner install.sh prints ──────────────────────
fresh_home
"$TEST_SH" "$INSTALL" > "$TEST_TMP/install.out" 2>&1
jq -n '{model: "opus", env: {FOO: "bar"}}' > "$DEST/settings.json"
# the printed command is the indented block from "jq -s" to the "mv" line
awk '/^  jq -s /{p=1} p{print} /&& mv /{p=0}' "$TEST_TMP/install.out" > "$TEST_TMP/merge.sh"
assert_contains "merge hint: install.sh prints a jq command" "$(cat "$TEST_TMP/merge.sh")" "settings.snippet.json"
"$TEST_SH" "$TEST_TMP/merge.sh" > /dev/null 2>&1
assert_eq "merge: exit code" "0" "$?"
assert_eq "merge: existing keys survive" "opus" "$(jq -r '.model' "$DEST/settings.json")"
assert_eq "merge: existing nested keys survive" "bar" "$(jq -r '.env.FOO' "$DEST/settings.json")"
assert_eq "merge: statusLine added" "bash ~/.claude/statusline-command.sh" "$(jq -r '.statusLine.command' "$DEST/settings.json")"
assert_eq "merge: PreToolUse hooks added" "2" "$(jq -r '.hooks.PreToolUse[0].hooks | length' "$DEST/settings.json")"
assert_eq "merge: UserPromptSubmit hooks added" "2" "$(jq -r '.hooks.UserPromptSubmit[0].hooks | length' "$DEST/settings.json")"
assert_no_file "merge: temp file moved away" "$DEST/settings.json.new"

# every script the snippet starts exists in this repo and is installed by install.sh
snippet_scripts=$(jq -r '[.statusLine.command, (.hooks[][].hooks[].command)] | unique | .[]' \
  "$ROOT/settings.snippet.json" | sed 's|.*/||')
for name in $snippet_scripts; do
  assert_file "snippet: $name exists in hooks/" "$ROOT/hooks/$name"
  case " $SCRIPTS " in
    *" $name "*) pass ;;
    *) fail "snippet: $name is not installed by install.sh" ;;
  esac
done

# ── uninstall ────────────────────────────────────────────────────────────────
fresh_home
"$TEST_SH" "$INSTALL" > /dev/null 2>&1
echo '{"keep": true}' > "$DEST/settings.json"
echo '{}' > "$DEST/rate-limit-state.json"
echo '{}' > "$DEST/rate-limit-wait.lock"
echo 'x' > "$DEST/unrelated.txt"
OUT=$("$TEST_SH" "$UNINSTALL" 2>&1)
assert_eq "uninstall: exit code" "0" "$?"
assert_contains "uninstall: manual follow-up is announced" "$OUT" "Still to do by hand"
for s in $SCRIPTS rate-limit-state.json rate-limit-wait.lock; do
  assert_no_file "uninstall: $s removed" "$DEST/$s"
done
assert_file "uninstall: settings.json left alone" "$DEST/settings.json"
assert_eq "uninstall: settings.json untouched" '{"keep": true}' "$(cat "$DEST/settings.json")"
assert_file "uninstall: unrelated file left alone" "$DEST/unrelated.txt"

# uninstalling when nothing is installed is not an error
"$TEST_SH" "$UNINSTALL" > /dev/null 2>&1
assert_eq "uninstall twice: exit code" "0" "$?"

# removing the installed symlinks must not delete the checkout's scripts
for s in $SCRIPTS; do
  assert_file "uninstall: source $s intact" "$ROOT/hooks/$s"
done

finish "test_install"
