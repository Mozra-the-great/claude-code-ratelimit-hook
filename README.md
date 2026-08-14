# claude-code-ratelimit-hook

Pause [Claude Code](https://claude.com/claude-code) automatically when a usage-limit window
fills up, and resume the paused task by itself once the window resets.

Three small POSIX shell scripts, no daemon, no dependencies beyond `jq` and `awk`.

## The problem

When a usage limit is reached mid-task, the session stops making progress and you find out
by watching it fail. You then have to come back later and tell it to continue. On an
unattended host — an agent left running overnight, a remote-control session you drive from
your phone — nobody is there to do that.

## How it works

Claude Code exposes `rate_limits.five_hour` and `rate_limits.seven_day` in exactly one
place: the JSON payload handed to the **statusline command**. That is the hinge the whole
design hangs on.

```
statusline-command.sh   renders the statusline AND caches rate_limits.*
        │                       to ~/.claude/rate-limit-state.json
        ▼
rate-limit-state.json   {five_hour:{used_percentage,resets_at}, seven_day:{…}, updated_at}
        │
        ├──► rate-limit-guard.sh    PreToolUse + UserPromptSubmit, blocking
        │    Over threshold and not past resets_at? Deny the call with a reason
        │    naming the reset time.
        │
        └──► rate-limit-waiter.sh   PreToolUse + UserPromptSubmit, async
             Sleeps until the soonest blocking reset, then exits 2 so the harness
             rewakes the model, which picks the task back up on its own.
```

Thresholds are 95% for the 5-hour window and 98% for the 7-day one, set at the top of
`rate-limit-guard.sh` and `rate-limit-waiter.sh`.

Two details worth knowing:

- The guard **whitelists** `ScheduleWakeup`, `CronCreate`, `CronDelete` and `CronList`, so
  the model can still arrange its own resume while everything else is blocked.
- The waiter dedupes through `~/.claude/rate-limit-wait.lock`, holding `{resets_at, pid}`
  and checking liveness with `kill -0`. Repeated hook firings while blocked therefore do
  not pile up overlapping sleepers.

## Install

```sh
git clone https://github.com/Mozra-the-great/claude-code-ratelimit-hook.git
cd claude-code-ratelimit-hook
./install.sh
```

Symlinks by default, so `git pull` updates the installed scripts; `./install.sh --copy`
installs real files instead. An existing real file at a target path is backed up to
`<name>.bak-<timestamp>` rather than overwritten. Honours `CLAUDE_CONFIG_DIR`.

The scripts install **flat** into `~/.claude/`, not `~/.claude/hooks/`, because the
settings snippet refers to `bash ~/.claude/<name>.sh`.

Then merge `settings.snippet.json` into `~/.claude/settings.json` — it contains only the
`statusLine` and `hooks` entries, nothing else. `install.sh` prints a `jq` one-liner for it.

Restart Claude Code and confirm the cache is being fed:

```sh
cat ~/.claude/rate-limit-state.json
```

A fresh `updated_at` means it works. Remove with `./uninstall.sh`.

### Requirements

`jq` (≥1.6), `awk`, GNU `date` (a BSD `date -r` fallback is built in), and `bash` on
`PATH` — the scripts are `#!/bin/sh` POSIX and contain no bashisms, but the settings
snippet invokes them as `bash ~/.claude/…`.

## Known limitations

**The statusline is the only data source.** If your statusline command is not configured,
or the statusline is not rendered in your context, `rate-limit-state.json` is never written
and the guard and waiter are silent no-ops. They fail open by design — nothing is blocked
when there is no data.

This matters most on headless hosts. If you run Claude Code as a service and the state file
never updates, try running it under a pseudo-terminal (`script -qe -c '…' /dev/null`).
Failing that, anything that writes the same JSON schema to `rate-limit-state.json` works as
a drop-in source — for example a watcher parsing usage-limit messages out of the service's
log. The guard and waiter read the file and nothing else, so no changes are needed to swap
the producer.

**The waiter's `timeout` may cut a long wait short.** The snippet sets `timeout: 610000` on
the async waiter. If the harness reads that as milliseconds (~10 minutes), a wait on the
7-day window will be killed before the sleep finishes; the 5-hour window is usually fine
because you rarely sit near a full window length. If you hit this, make the waiter sleep in
chunks — `min(remaining, 540)` per firing — and let the next hook firing re-arm it, instead
of one long sleep.

**Percentages are only as fresh as the last statusline render.** The guard treats a cached
window whose `resets_at` has already passed as not blocking, so stale state expires on its
own rather than blocking forever.

## License

GNU General Public License v3.0 — see [`LICENSE`](LICENSE).
