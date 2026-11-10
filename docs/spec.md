# lidsomnia — spec

Keep a MacBook awake — **including with the lid closed on battery** — while a wrapped job runs. The primary use case is a `claude` Remote Control session driven from a phone.

Status: v1 design, agreed 2026-11-08. Renamed from **lidless** in 2.1.0; see the roadmap for how old installs migrate.

## Why root is needed

macOS power assertions (`caffeinate`, `IOPMAssertion*`) do **not** prevent lid-close sleep on battery without an external display. The only reliable switch is the global `SleepDisabled` flag:

```
sudo pmset -a disablesleep 1   # never sleep, even with lid closed
sudo pmset -a disablesleep 0   # normal behaviour
```

The flag is system-wide and survives the process that set it, so lidsomnia must guarantee it gets turned back off (see *Crash safety*).

## Commands

| Command | Purpose |
|---|---|
| `lidsomnia [--sleep-after] <cmd> [args…]` | Run `<cmd>`, keep the Mac awake while it is active. |
| `lidsomnia setup` | Install the sudoers rule and the launchd watchdog (prompts for password once). |
| `lidsomnia uninstall` | Remove both, and reset `disablesleep 0`. |
| `lidsomnia status` | Show holds, busy/idle state, battery, thermal, `SleepDisabled`. |
| `lidsomnia release` | Panic button: drop all holds and set `disablesleep 0`. |
| `lidsomnia doctor` | Check the setup; print the exact fix for each problem. Exit 1 if anything fails. |
| `lidsomnia test-alert` | Send a test alert to the configured channels. |
| `lidsomnia reap` | Hidden. Run by the watchdog every 60 s. |
| `lidsomnia hook <busy\|idle>` | Hidden. Invoked by Claude Code hooks. |

## Wrapper behaviour

- The child inherits the terminal directly (stdin/stdout/stderr, same process group). No PTY proxy.
- `SIGTERM` and `SIGHUP` are forwarded to the child. `SIGINT` reaches the child from the terminal directly; lidsomnia ignores it itself.
- lidsomnia exits with the child's exit code (`128 + signal` if the child was killed by a signal).
- The hold is dropped the moment the child exits.
- `--sleep-after`: when the child exits and no other holds remain, run `pmset sleepnow`.

## Holds

Each running wrapper owns one **hold**, stored in `~/.lidsomnia/holds/`:

- `<pid>.json` — written only by the wrapper: `pid`, `childPid`, `command`, `kind` (`plain`/`claude`), `startedAt`, `held`, `reason`.
- `<pid>.activity` — written only by Claude hooks: `state` (`busy`/`idle`), `at`.

Split files mean the wrapper and hooks never write the same file. All writes are atomic (temp file + rename).

**Reconcile rule:** `SleepDisabled` should be `1` iff at least one hold whose wrapper process is alive has `held: true`. Every state change (own hold updated, hold removed, reap) runs reconcile **under an exclusive `flock` on `~/.lidsomnia/lock`**, so two wrappers can't race each other into the wrong final state. Reconcile reads the current flag first and only calls `sudo pmset` when it needs to change.

A hold whose wrapper pid is dead (or whose pid now belongs to a non-lidsomnia process) is deleted during reconcile.

## Activity / idle detection

- **Plain commands** (`kind: plain`) are active for as long as they run.
- **Claude commands** (`kind: claude`, i.e. `basename(argv[0]) == "claude"`) get idle detection via Claude Code hooks, injected per-run with `--settings '<json>'`. The user's global settings are untouched.

| Hook event | Marks |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | busy |
| `Stop`, `Notification` (idle prompt / waiting for permission) | idle |

Hooks run `"<abs path to lidsomnia>" hook busy|idle`; the activity file path is passed via the `LIDSOMNIA_ACTIVITY_FILE` env var that the wrapper sets on the child (hooks inherit it). The hook command always exits 0 and never blocks Claude.

If the user already passes `--settings <file-or-json>`, lidsomnia loads it, appends its hook entries to the existing `hooks` arrays, and passes a single merged JSON value.

A Claude session with no activity file yet counts as idle since `startedAt`.

## Decision logic

A pure function evaluated every 30 s (and immediately at start):

```
decide(kind, activity, readings, config, now, manuallyReleased) -> (held, reason)
```

In order:

1. `manuallyReleased` (the hold file was removed by `lidsomnia release`) → release, `manual`. Stays released for the rest of the run.
2. On battery and `batteryPercent <= batteryFloorPercent` → release, `lowBattery`.
3. `thermalState >= thermalLimit` → release, `thermal`. Re-acquired automatically once below the limit (with the default `serious`, that means `fair` or `nominal`).
4. Battery temperature `>= batteryTempLimitC` → release, `hot`. Re-acquired only once it's 5 °C below the limit (see [bag mode](#bag-mode-and-low-power-mode-v240)).
5. `kind == claude`, state idle, and `now - lastActivity >= idleTimeoutMinutes` → release, `idle`. A later `busy` hook re-acquires.
6. Otherwise → hold, `active`.

On a transition from held → released for `lowBattery`, `thermal` or `hot`, send a macOS notification (if `notify`).

## Safety defaults

`~/.lidsomnia/config.json`, every key optional:

```json
{
  "idleTimeoutMinutes": 30,
  "batteryFloorPercent": 10,
  "thermalLimit": "serious",
  "batteryTempLimitC": 45,
  "lowPowerWhenClosed": true,
  "notify": true
}
```

`thermalLimit` is one of `fair`, `serious`, `critical`. No hard session cap.

## Codex (v2.0.4)

`lidsomnia codex …` and auto-detect support OpenAI's Codex CLI alongside Claude Code (`kind: codex`).

- **Why no hooks:** Codex has Claude-style hooks (`UserPromptSubmit`, `PreToolUse`, `Stop`, …), but every hook must be approved once in Codex before it runs; hooks injected per run (`-c hooks.*` or a fresh `hooks.json`) are silently skipped. lidsomnia won't use `--dangerously-bypass-hook-trust`, since that disables review for all hooks.
- **Activity:** the newest write to a session file in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` since the hold started, preferring sessions whose `session_meta.payload.cwd` matches the hold's cwd. If none match (e.g. `codex -C dir`, or VS Code's app-server running from `/`), the newest write of any session counts, which errs toward staying awake. Resumed sessions append to their original file in an older day folder, so the whole tree is scanned (cheap: one stat per file).
- **Same timeout and rules** as Claude: `idleTimeoutMinutes`, battery, thermal, alerts.
- **Detected processes:** binaries launched as `codex` (Homebrew, standalone, the VS Code extension's `app-server`) or node running `@openai/codex`. `codex remote-control start` daemonizes, so it can only be covered by auto-detect; the wrapper warns about it.
- **Detection uses `argv[0]` when readable:** both agents' native binaries re-execute themselves under other names for helpers (Claude Code runs its bundled `ugrep`; Codex runs `apply_patch`), and those must not be adopted as sessions. Processes whose parent is an agent are skipped as helpers.

### Codex hooks (v2.2.0, opt-in)

Session files miss one case: a single long command with no session writes looks idle and can be released mid-task. `lidsomnia setup --codex-hooks` adds hooks for hook-level precision:

- **Install:** merges six handlers into `$CODEX_HOME/hooks.json` (default `~/.codex`), keeping any hooks already there and backing the file up once to `hooks.json.bak`. `UserPromptSubmit`, `PreToolUse` and `PostToolUse` run `lidsomnia hook codex busy`; `Stop`, `Interrupt` and `SessionEnd` run `lidsomnia hook codex idle` (3 s timeout). Re-running replaces them; `uninstall` removes them.
- **Approval:** Codex skips new hooks until you trust them once with `/hooks` (trust is tied to each hook's hash, so the command uses the stable Homebrew path, not the Cellar). lidsomnia never bypasses this.
- **Finding the hold:** the hooks are global, so the hook walks up its parent processes until it reaches a held Codex process, which is the hold's `childPid` for wrapped runs or the hold's own pid for auto-detected ones. No environment variables are needed, and hooks from unrelated Codex sessions do nothing. Output is silent, because Codex can parse hook stdout.
- **Activity:** a `busy` hook keeps the session busy until an idle hook. Otherwise the newest of the idle hook, session writes and the hold's start counts, so sessions without approved hooks fall back to session files as before. A busy hook on an idle-released hold wakes the wrapper (`SIGUSR1`).
- **Doctor:** each hook run touches `~/.lidsomnia/codex-hooks-seen`, so `doctor` can tell "installed but not approved yet" from "approved and running".

## Doctor (v2.0.3)

`lidsomnia doctor` gathers facts from the system and evaluates them with a pure, unit-tested function (`Doctor.evaluate`). Each check is ✓ ok, ! warn or ✗ fail, with a `fix:` command.

| Check | Fails / warns when |
|---|---|
| sudoers | `sudo -n -l` lists no passwordless entry for `/usr/bin/pmset -a disablesleep 0` (fail → `lidsomnia setup`). Asking `sudo -l <command>` isn't used: an admin's `(ALL) ALL` "permits" everything, with a password the watchdog can't type |
| watchdog | plist missing, its binary missing, or not loaded (fail); points at a different binary than the one running, or last exit ≠ 0 (warn) → `lidsomnia setup --agent-only` |
| binary | more than one `lidsomnia` on PATH (warn) |
| sleep flag | `SleepDisabled 1` with no live held hold (fail → `lidsomnia release`) |
| holds | hold files left by dead processes (warn → `lidsomnia reap`) |
| config | invalid JSON or wrong types (fail); unknown keys such as typos (warn) |
| alerts | invalid ntfy server or webhook URL (fail); configured → suggests `lidsomnia test-alert` |
| auto-detect | on but the watchdog isn't loaded (fail) |
| claude | not on PATH (warn) |
| power | battery at the floor, battery temperature or thermal at the limit, so holds would be released (warn). Shows the time to the floor, battery temperature and lid state |
| low power | `lowPowerWhenClosed` is on but the sudoers rule predates it (warn → `lidsomnia setup`) |

## Auto-detect (v2.0.2)

Opt-in with `"autoDetect": true`. The watchdog (`lidsomnia reap`, every 60 s) also keeps the Mac awake for `claude` sessions that weren't started through lidsomnia, including `claude --bg` background sessions.

- **Detection:** a process is Claude Code if its executable is under `…/claude/versions/…` (native install; the kernel process name is the version number), its binary or `argv[0]` is `claude`, or it is `node` running `@anthropic-ai/claude-code`. Process info comes from `proc_listallpids`, `proc_pidpath`, `KERN_PROCARGS2` (argv) and `proc_pidinfo` (parent pid, cwd).
- **Skipped:** sessions already wrapped (pid is a wrapper's `childPid`, or parent is a live lidsomnia wrapper) and sessions already adopted.
- **Adopted hold:** a hold record with `adopted: true`, `pid` = the claude process, and its `cwd`. Liveness checks that the pid is still a Claude Code process.
- **Activity:** hooks can't be injected into a running process, so activity is the newest `*.jsonl` write in `~/.claude/projects/<cwd with non-alphanumerics replaced by "-">/`, never earlier than the adoption time. The same `idleTimeoutMinutes` applies. Weaker than hooks: a single tool call running longer than the timeout without transcript writes can be released mid-task.
- **Same rules:** battery, thermal and idle decisions, alerts (no `finished` alert: there's no exit code to report), and macOS notifications.
- `lidsomnia release` marks adopted holds as manually released instead of deleting them, so they aren't immediately re-adopted. Turning `autoDetect` off drops all adopted holds on the next reap.

## Phone alerts (v2.0)

With the lid shut you're on your phone, so a macOS notification is never seen. lidsomnia can push alerts through [ntfy](https://ntfy.sh) and/or a generic webhook.

```json
{
  "alerts": {
    "ntfyTopic": "a-long-random-topic",
    "ntfyServer": "https://ntfy.sh",
    "ntfyToken": "tk_…",
    "webhookURL": "https://example.com/hook",
    "events": ["lowBattery", "batterySoon", "thermal", "hotSoon", "hot", "idleSoon", "idle", "finished"],
    "finishedMinMinutes": 5,
    "idleWarningMinutes": 5,
    "batteryWarningMinutes": 15,
    "phoneControl": true,
    "controlTopic": "a-long-random-topic-control"
  }
}
```

All keys are optional; alerts are off until `ntfyTopic` or `webhookURL` is set.

| Event | Sent when |
|---|---|
| `idleSoon` | `idleWarningMinutes` before an idle release (once per release time), with phone buttons |
| `batterySoon` | the battery is estimated to reach the floor within `batteryWarningMinutes` while something is held (once per discharge), with a Sleep now button |
| `hotSoon` | the battery is within 3 °C of `batteryTempLimitC` while something is held (once per warm spell), with a Sleep now button |
| `lowBattery`, `thermal`, `hot`, `idle` | a hold goes from held to released for that reason |
| `finished` | the wrapped command exits after running at least `finishedMinMinutes`; includes exit code and duration |
| `test` | `lidsomnia test-alert` (ignores `events`) |

- **ntfy** uses JSON publishing (`POST <server>` with `topic`, `title`, `message`, `priority`, `tags`), so non-ASCII host names work. `ntfyToken` adds `Authorization: Bearer`.
- **Webhook** receives the event as JSON (`kind`, `host`, `command`, `pid`, `exitCode`, `durationSeconds`, `batteryPercent`, `onBattery`, `thermal`, `at`) plus `title` and `message`.
- **Ordering:** alerts are sent synchronously (5 s timeout per request) **before** the hold is released, because with the lid shut the Mac sleeps right after and the request would never leave.
- Failures are logged to stderr and never affect the wrapped command.

## Phone control (v2.2.0)

Alert buttons that act on the Mac. A button can't usefully appear on the `idle` alert itself: by then the hold is released and a closed Mac is asleep within seconds. So the buttons go on the `idleSoon` warning, sent while there's still time:

> **Claude idle on MacBook: sleeping in 5 min** · [Keep awake 1h] [Sleep now]

- **Transport.** Buttons are ntfy `http` actions. The phone POSTs a one-line command straight to a second topic, `controlTopic` (default `<ntfyTopic>-control`); `ntfyToken` is passed along as a header. No server, no extra app.
- **Commands.** `extend <pid> <startedAt> <minutes>` (1–240) and `sleep <pid> <startedAt>`, plus `ping <token>` for `test-alert`. A hold is named by pid *and* start time, so a late tap can't hit a later job that reused the pid. Anything else is ignored.
- **Pickup.** The watchdog polls the control topic (`GET …/json?poll=1&since=<last id>`) on each 60 s run, but only while holds exist. Taps older than 15 minutes are dropped. The cursor lives in `~/.lidsomnia/control-since`, so each tap is applied once.
- **Keep awake** writes `holds/<pid>.extend`; the decision then won't release for idle before that time (battery and heat still win). The wrapper is woken with `SIGUSR1`. A fresh `idleSoon` warning goes out before the extension runs out, so you can extend again.
- **Sleep now** releases that hold for the rest of its run (like `release`). If nothing else holds the Mac awake, it runs `pmset sleepnow`.
- **Confirmations.** `extended`, `sleeping` or `released` is pushed back so you know the tap landed. These ignore `events`.
- **Trust model.** The control topic appears in the alerts' button URLs, so anyone who can read your alert topic can send commands. Keep the topic long and random, the same as for alerts. The worst they can do is keep the Mac awake for up to 4 hours (still within the battery and heat limits) or put it to sleep. Set `"phoneControl": false` to turn buttons off.
- **`test-alert`** adds a "Test button" and waits up to 90 s for your tap, checking the whole round trip (`--no-wait` to skip).

## Battery estimate (v2.3.0)

- **Estimate.** macOS reports minutes to empty at the current load (`Time to Empty` from IOKit power sources; unavailable on AC and while it's calculating). lidsomnia scales it to the floor: `minutesToEmpty × (percent − floor) / percent`. `status` and `doctor` show it as "about 2h10m to the 10% floor".
- **Warning.** On each 60 s run the watchdog sends one `batterySoon` alert when something is held and the estimate is within `batteryWarningMinutes` (default 15; 0 turns it off). It's machine-wide, so there's one alert however many jobs are held. `~/.lidsomnia/battery-warned` records it; it re-arms when the Mac is on AC or nothing is held.
- **Button.** **Sleep now** posts `sleep-all`: every hold is released (like `release`), a `sleeping` confirmation is sent, then `pmset sleepnow`. There's no keep-awake button, because the battery floor is a safety limit; plug in to keep going.

## Bag mode and Low Power Mode (v2.4.0)

The real risk of closed-lid running is a Mac working hard inside a bag.

- **Readings.** Battery temperature (`Temperature` on the `AppleSmartBattery` IOKit service, in hundredths of a °C) and lid state (`AppleClamshellState` on `IOPMrootDomain`). Neither needs root. `status` and `doctor` show both.
- **Why battery temperature.** It climbs steadily in an enclosed space and it's what heat damages. macOS's thermal state only reaches `serious` once the chip is throttling hard. Chip temperatures need root (`powermetrics`) and swing with every burst of work.
- **Limit.** `batteryTempLimitC` (default 45). At the limit the hold is released with reason `hot` and a `hot` alert; it comes back once the battery is 5 °C cooler, so it doesn't flap around the limit. The rule applies whether or not the lid is closed; with the lid open you're at the Mac, and a release only restores normal sleep.
- **Warning.** The watchdog sends one `hotSoon` alert per warm spell when the battery is within 3 °C of the limit and something is held, saying the lid is closed when it is. It has a **Sleep now** button (`sleep-all`). `~/.lidsomnia/heat-warned` records it; it re-arms once the battery is 5 °C below the limit or nothing is held.
- **Defaults are a first guess.** 45 °C is the usual upper limit for charging lithium-ion cells. A first in-bag sample on a 14" M1 Max (two Claude sessions, 11–25 W) read 30–31 °C; tune after more real runs.
- **Low Power Mode.** With `lowPowerWhenClosed` (default on), the watchdog runs `pmset -b lowpowermode 1` while the lid is closed and something is held, and turns it back off when the lid opens or the last hold ends (within a minute; also straight away on `release`, `uninstall`, a phone Sleep now, and when the last wrapper exits). Battery power only, so it never applies on AC. Agent sessions mostly wait on the network, so the slower chip costs little; it draws less and runs cooler, which helps the heat limit.
- **Your setting wins.** `~/.lidsomnia/low-power` records what lidsomnia did. If Low Power Mode was already on, lidsomnia never touches it. If you turn it off while lidsomnia had it on, it stays off until the next time it's wanted from scratch. Without the updated sudoers rule it quietly does nothing and `doctor` says so.

## Privilege model

`lidsomnia setup` writes `/etc/sudoers.d/lidsomnia` (mode 0440, validated with `visudo -cf` before installing):

```
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1
```

The two `lowpowermode` entries arrived in 2.4.0; rules installed earlier keep working, and Low Power Mode stays off until `lidsomnia setup` is run again.

lidsomnia calls `sudo -n /usr/bin/pmset …` so it fails fast instead of prompting. If the rule is missing, the wrapper prints a one-line hint to run `lidsomnia setup` and still runs the command (without keeping the Mac awake).

## Crash safety

1. **Signal handlers** in the wrapper: on `SIGTERM`/`SIGHUP` forward to the child, wait, drop hold, reconcile.
2. **Watchdog**: launchd user agent `com.lidsomnia.watchdog` (`~/Library/LaunchAgents/com.lidsomnia.watchdog.plist`) runs `lidsomnia reap` every 60 s. Reap = reconcile: delete dead holds; if `SleepDisabled == 1` and no live held hold exists, set it to 0. This is the only layer that catches `kill -9` or a closed terminal window that doesn't deliver `SIGHUP`.

## Architecture

SwiftPM package, no third-party dependencies (subcommands are dispatched by hand so passthrough args like `lidsomnia claude --remote-control` are never touched).

- `LidsomniaCore` (library): decision logic, hold store, reconcile, config, settings merge. All side effects behind protocols:
  - `PowerControl` — read/set `SleepDisabled`, `sleepNow`
  - `PowerReadings` — battery %, on-battery, thermal state
  - `Clock` — `now`
  - `ProcessProbe` — is pid a live lidsomnia process
  - `Notifier`
- `lidsomnia` (executable): argument parsing, process spawning, signal handling, real implementations of the protocols (`pmset` via `sudo -n`, IOKit power sources, `ProcessInfo.thermalState`, `kill(pid, 0)` + `proc_pidpath`, `osascript`).
- `LidsomniaCoreTests`: Swift Testing; exercises decision logic, reconcile, reaping and settings merge with fakes. No test touches real power settings.

Install: `make install` → `~/.local/bin/lidsomnia`.

## Out of scope for v1

- Auto-detecting `claude` processes not started through lidsomnia.
- `claude --bg` background sessions can't be wrapped (the CLI exits immediately); auto-detect (v2.0.2) covers them.
- Phone alerts (v2: optional `webhookURL`, e.g. ntfy.sh).
- Homebrew formula, code signing, privileged helper, GUI.

## Known caveats

- lidsomnia owns the `SleepDisabled` flag. If you set `pmset disablesleep 1` by hand, the watchdog will reset it within 60 s whenever no lidsomnia hold exists.
- Verified 2026-11-08 (Claude Code 2.1.319): `--settings` with injected hooks is accepted, and `PreToolUse` writes `busy` to the activity file during a real session.

## Resolved: Remote Control prompts

Verified 2026-11-08 on a real device: prompts sent from the phone through Remote Control fire the injected hooks. Both a plain chat prompt and a tool-using prompt flip the activity to `busy` and back to `idle` on `Stop`. No fallback needed. Closed-lid keep-awake on battery was also verified (test 1 in the checklist).

## Manual test checklist

1. `lidsomnia setup`, then `sudo -n pmset -a disablesleep 0` succeeds without a prompt.
2. `lidsomnia sleep 120`, close lid on battery, reopen after 90 s — `sleep` still running, `pmset -g log` shows no sleep.
3. After the child exits, `pmset -g | grep SleepDisabled` → `0`.
4. `kill -9` the wrapper; within 60 s `SleepDisabled` returns to `0`.
5. Two concurrent wrappers: ending one keeps `SleepDisabled 1`; ending both resets it.
6. `lidsomnia claude --remote-control`, send a prompt from the phone, check `~/.lidsomnia/holds/*.activity` flips to `busy`.
7. Set `idleTimeoutMinutes: 1`, idle Claude session → `lidsomnia status` shows `released (idle)` after ~1 min.
8. `lidsomnia release` while a wrapper runs → `SleepDisabled 0`, wrapper stays released.
