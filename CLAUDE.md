# claude-code-ratelimit-hook

## Type
Public repo of three POSIX shell hooks (`hooks/`) plus `install.sh` / `uninstall.sh` and
`settings.snippet.json`. It is also a git submodule of the private `claude-code-global-config`.

## Important
- The hooks are **live** on the maintainer's machine (`~/.claude/rate-limit-*.sh`). Never run
  `install.sh` / `uninstall.sh` or any hook against the real `~/.claude` while developing.
  The tests use a throw-away `HOME` (see `tests/lib.sh`).
- Scripts stay POSIX `sh` (no bashisms) but are started with `bash` by the settings snippet.

## Commands
```sh
sh tests/run-all.sh                  # all behaviour tests (needs jq)
TEST_SH=bash sh tests/run-all.sh     # run the hooks under bash instead of sh
sh tests/test_guard.sh               # a single suite
shellcheck --shell=sh install.sh uninstall.sh hooks/*.sh tests/*.sh
```

## CI (`.github/workflows/`)
- `ci.yml`: jobs `shellcheck` and `test` (stable names, no path filter).
- `workflow-lint.yml`: actionlint + zizmor. `secret-scan.yml`: gitleaks on PRs.
- No Claude workflows by design (shell hooks, rare PRs).
- Actions are pinned by commit SHA with a version comment; Dependabot keeps them fresh.
- CodeQL runs as GitHub default setup (actions, default suite, not a workflow file); the `CodeQL` status check is required by the ruleset.

## Conventions
- Conventional commits in English, feature branches, no direct pushes to `main`.
- Changing a threshold (95 / 98), the tool whitelist or the exit-code/JSON contract of a hook
  must come with a matching change in `tests/`.
