#!/bin/sh
# Shared helpers for the behaviour tests. Sourced, never executed on its own.
#
# Safety: every test runs in a throw-away HOME. Sourcing this file repoints HOME
# at a fresh temp dir and unsets CLAUDE_CONFIG_DIR, so a test can never read or
# write the real ~/.claude (the hooks are live on the machine that develops them).

# shellcheck disable=SC2034  # used by the sourcing test files
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# Shell that runs the hooks. The settings snippet starts them with `bash`, the
# scripts themselves are `#!/bin/sh` POSIX, so CI exercises both.
TEST_SH=${TEST_SH:-sh}

command -v jq >/dev/null 2>&1 || { echo "tests: jq is required" >&2; exit 1; }

TEST_TMP=$(mktemp -d)
HOME=$TEST_TMP/home
export HOME
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude"
trap 'rm -rf "$TEST_TMP"' EXIT
trap 'exit 130' INT TERM

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then
    pass
  else
    fail "$1: expected '$2', got '$3'"
  fi
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) pass ;;
    *) fail "$1: expected to contain '$3', got '$2'" ;;
  esac
}

# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1: expected NOT to contain '$3', got '$2'" ;;
    *) pass ;;
  esac
}

# assert_file <name> <path>      assert_no_file <name> <path>
assert_file() {
  if [ -e "$2" ]; then pass; else fail "$1: missing $2"; fi
}
assert_no_file() {
  if [ -e "$2" ] || [ -L "$2" ]; then fail "$1: unexpected $2"; else pass; fi
}

# fresh_home: empty ~/.claude for the next case
fresh_home() {
  rm -rf "$HOME"
  mkdir -p "$HOME/.claude"
}

# write_state <five_used> <five_resets> <seven_used> <seven_resets>
# Writes ~/.claude/rate-limit-state.json in the schema statusline-command.sh
# produces. An argument of "null" for the used value yields a JSON null window.
# The values are kept as given (strings stay strings), so malformed fixtures work.
write_state() {
  jq -n --arg fu "$1" --arg fr "$2" --arg su "$3" --arg sr "$4" '
    def num: if test("^[0-9.]+$") then tonumber else . end;
    def win(u; r): if u == "null" then null
      else {used_percentage: (u | num), resets_at: (r | num)} end;
    {five_hour: win($fu; $fr), seven_day: win($su; $sr), updated_at: 0}
  ' > "$HOME/.claude/rate-limit-state.json"
}

# finish <suite name>: print the result and exit non-zero on any failure
finish() {
  if [ "$FAIL" -gt 0 ]; then
    echo "$1: $FAIL failed, $PASS passed" >&2
    exit 1
  fi
  echo "$1: $PASS passed"
}
