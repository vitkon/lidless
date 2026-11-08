# lidless — spec

Keep a MacBook awake — **including with the lid closed on battery** — while a wrapped job runs. The primary use case is a `claude` Remote Control session driven from a phone.

Status: v1 design, agreed 2026-11-08.

## Why root is needed

macOS power assertions (`caffeinate`, `IOPMAssertion*`) do **not** prevent lid-close sleep on battery without an external display. The only reliable switch is the global `SleepDisabled` flag:

```
sudo pmset -a disablesleep 1   # never sleep, even with lid closed
sudo pmset -a disablesleep 0   # normal behaviour
```

The flag is system-wide and survives the process that set it, so lidless must guarantee it gets turned back off (see *Crash safety*).

## Commands

| Command | Purpose |
|---|---|
| `lidless [--sleep-after] <cmd> [args…]` | Run `<cmd>`, keep the Mac awake while it is active. |
| `lidless setup` | Install the sudoers rule and the launchd watchdog (prompts for password once). |
| `lidless uninstall` | Remove both, and reset `disablesleep 0`. |
| `lidless status` | Show holds, busy/idle state, battery, thermal, `SleepDisabled`. |
| `lidless release` | Panic button: drop all holds and set `disablesleep 0`. |
| `lidless reap` | Hidden. Run by the watchdog every 60 s. |
| `lidless hook <busy\|idle>` | Hidden. Invoked by Claude Code hooks. |

## Wrapper behaviour

- The child inherits the terminal directly (stdin/stdout/stderr, same process group). No PTY proxy.
- `SIGTERM` and `SIGHUP` are forwarded to the child. `SIGINT` reaches the child from the terminal directly; lidless ignores it itself.
- lidless exits with the child's exit code (`128 + signal` if the child was killed by a signal).
- The hold is dropped the moment the child exits.
- `--sleep-after`: when the child exits and no other holds remain, run `pmset sleepnow`.

## Holds

Each running wrapper owns one **hold**, stored in `~/.lidless/holds/`:

- `<pid>.json` — written only by the wrapper: `pid`, `childPid`, `command`, `kind` (`plain`/`claude`), `startedAt`, `held`, `reason`.
- `<pid>.activity` — written only by Claude hooks: `state` (`busy`/`idle`), `at`.

Split files mean the wrapper and hooks never write the same file. All writes are atomic (temp file + rename).

**Reconcile rule:** `SleepDisabled` should be `1` iff at least one hold whose wrapper process is alive has `held: true`. Every state change (own hold updated, hold removed, reap) runs reconcile **under an exclusive `flock` on `~/.lidless/lock`**, so two wrappers can't race each other into the wrong final state. Reconcile reads the current flag first and only calls `sudo pmset` when it needs to change.

A hold whose wrapper pid is dead (or whose pid now belongs to a non-lidless process) is deleted during reconcile.

## Activity / idle detection

- **Plain commands** (`kind: plain`) are active for as long as they run.
- **Claude commands** (`kind: claude`, i.e. `basename(argv[0]) == "claude"`) get idle detection via Claude Code hooks, injected per-run with `--settings '<json>'`. The user's global settings are untouched.

| Hook event | Marks |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | busy |
| `Stop`, `Notification` (idle prompt / waiting for permission) | idle |

Hooks run `"<abs path to lidless>" hook busy|idle`; the activity file path is passed via the `LIDLESS_ACTIVITY_FILE` env var that the wrapper sets on the child (hooks inherit it). The hook command always exits 0 and never blocks Claude.

If the user already passes `--settings <file-or-json>`, lidless loads it, appends its hook entries to the existing `hooks` arrays, and passes a single merged JSON value.

A Claude session with no activity file yet counts as idle since `startedAt`.

## Decision logic

A pure function evaluated every 30 s (and immediately at start):

```
decide(kind, activity, readings, config, now, manuallyReleased) -> (held, reason)
```

In order:

1. `manuallyReleased` (the hold file was removed by `lidless release`) → release, `manual`. Stays released for the rest of the run.
2. On battery and `batteryPercent <= batteryFloorPercent` → release, `lowBattery`.
3. `thermalState >= thermalLimit` → release, `thermal`. Re-acquired automatically once below the limit (with the default `serious`, that means `fair` or `nominal`).
4. `kind == claude`, state idle, and `now - lastActivity >= idleTimeoutMinutes` → release, `idle`. A later `busy` hook re-acquires.
5. Otherwise → hold, `active`.

On a transition from held → released for `lowBattery` or `thermal`, send a macOS notification (if `notify`).

## Safety defaults

`~/.lidless/config.json`, every key optional:

```json
{
  "idleTimeoutMinutes": 30,
  "batteryFloorPercent": 10,
  "thermalLimit": "serious",
  "notify": true
}
```

`thermalLimit` is one of `fair`, `serious`, `critical`. No hard session cap.

## Privilege model

`lidless setup` writes `/etc/sudoers.d/lidless` (mode 0440, validated with `visudo -cf` before installing):

```
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
```

lidless calls `sudo -n /usr/bin/pmset …` so it fails fast instead of prompting. If the rule is missing, the wrapper prints a one-line hint to run `lidless setup` and still runs the command (without keeping the Mac awake).

## Crash safety

1. **Signal handlers** in the wrapper: on `SIGTERM`/`SIGHUP` forward to the child, wait, drop hold, reconcile.
2. **Watchdog**: launchd user agent `com.lidless.watchdog` (`~/Library/LaunchAgents/com.lidless.watchdog.plist`) runs `lidless reap` every 60 s. Reap = reconcile: delete dead holds; if `SleepDisabled == 1` and no live held hold exists, set it to 0. This is the only layer that catches `kill -9` or a closed terminal window that doesn't deliver `SIGHUP`.

## Architecture

SwiftPM package, no third-party dependencies (subcommands are dispatched by hand so passthrough args like `lidless claude --remote-control` are never touched).

- `LidlessCore` (library): decision logic, hold store, reconcile, config, settings merge. All side effects behind protocols:
  - `PowerControl` — read/set `SleepDisabled`, `sleepNow`
  - `PowerReadings` — battery %, on-battery, thermal state
  - `Clock` — `now`
  - `ProcessProbe` — is pid a live lidless process
  - `Notifier`
- `lidless` (executable): argument parsing, process spawning, signal handling, real implementations of the protocols (`pmset` via `sudo -n`, IOKit power sources, `ProcessInfo.thermalState`, `kill(pid, 0)` + `proc_pidpath`, `osascript`).
- `LidlessCoreTests`: Swift Testing; exercises decision logic, reconcile, reaping and settings merge with fakes. No test touches real power settings.

Install: `make install` → `~/.local/bin/lidless`.

## Out of scope for v1

- Auto-detecting `claude` processes not started through lidless.
- `claude --bg` background sessions (the `claude` CLI process exits immediately; nothing to wrap).
- Phone alerts (v2: optional `webhookURL`, e.g. ntfy.sh).
- Homebrew formula, code signing, privileged helper, GUI.

## Known caveats

- lidless owns the `SleepDisabled` flag. If you set `pmset disablesleep 1` by hand, the watchdog will reset it within 60 s whenever no lidless hold exists.
- Verified 2026-11-08 (Claude Code 2.1.319): `--settings` with injected hooks is accepted, and `PreToolUse` writes `busy` to the activity file during a real session.

## Open question to verify during implementation

Do prompts sent from the phone through Remote Control fire `UserPromptSubmit` in the local session? If not, a phone prompt after the idle cutoff won't re-acquire the hold (and the Mac may already be asleep). Fallback if needed: treat RC sessions as never idle, or count transcript writes as activity.

## Manual test checklist

1. `lidless setup`, then `sudo -n pmset -a disablesleep 0` succeeds without a prompt.
2. `lidless sleep 120`, close lid on battery, reopen after 90 s — `sleep` still running, `pmset -g log` shows no sleep.
3. After the child exits, `pmset -g | grep SleepDisabled` → `0`.
4. `kill -9` the wrapper; within 60 s `SleepDisabled` returns to `0`.
5. Two concurrent wrappers: ending one keeps `SleepDisabled 1`; ending both resets it.
6. `lidless claude --remote-control`, send a prompt from the phone, check `~/.lidless/holds/*.activity` flips to `busy`.
7. Set `idleTimeoutMinutes: 1`, idle Claude session → `lidless status` shows `released (idle)` after ~1 min.
8. `lidless release` while a wrapper runs → `SleepDisabled 0`, wrapper stays released.
