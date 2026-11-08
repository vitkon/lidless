# lidless — roadmap

v1 (shipped 2026-11-08) is described in [spec.md](spec.md). This file tracks what comes next, roughly in priority order. Each item lists the problem it solves, the proposed design, and the open questions to settle before building it.

## v1.1: hardening and Homebrew (done)

| Item | Problem | Fix |
|---|---|---|
| Honest status when pmset fails | `lidless status` showed `holding` even if `sudo pmset` was refused. | Hold records carry `effective`; status shows `NOT holding (sudo pmset failed…)`. |
| Instant re-acquire | After an idle release, a new prompt waited up to 30 s for the next tick. | The `busy` hook sends `SIGUSR1` to the wrapper (`LIDLESS_PID`), which re-evaluates immediately. |
| Strict argument parsing | `lidless setup -S` silently ignored `-S`. | Unknown flags and arguments are usage errors (exit 2). |
| Watchdog follows installs | The LaunchAgent pointed at whichever binary ran `setup`. | `make install` re-runs `lidless setup --agent-only`; the binary path is no longer symlink-resolved, so Homebrew's stable `/opt/homebrew/bin/lidless` survives upgrades. |
| Homebrew | Install meant cloning and `make install`. | `brew install vitkon/tap/lidless`. Source-build formula from the tagged tarball, published by `scripts/release.sh <version>`. |
| `--version` | No way to tell which build is installed. | `lidless --version`. |

Remote Control phone prompts were verified to fire the hooks, so no fallback was needed.

## v2.0: phone alerts (webhook)

**Problem.** With the lid shut you're on your phone, so a macOS notification saying "letting the Mac sleep: battery low" is never seen. You find out only when the RC session goes dark.

**Design.**
- New config keys: `webhookURL` and `webhookEvents` (default `["lowBattery", "thermal", "idle", "exited"]`).
- POST JSON `{event, reason, command, pid, battery, thermal, at}` with a 5 s timeout, fire-and-forget, from the wrapper.
- First-class shortcut for [ntfy.sh](https://ntfy.sh): `"ntfyTopic": "my-mac"` posts a plain-text message with title and priority headers, no JSON wrangling.
- `lidless test-alert` sends a sample event so you can check the wiring.

**Open questions.** Should `exited` (job finished) be on by default? It's the most useful signal for long builds, but noisy for short commands. A minimum run time (e.g. only for jobs longer than 5 min) might settle it.

## v2.1: Homebrew bottles

**Problem.** The v1.1 formula builds from source, so users need Xcode or the Command Line Tools and wait for a compile.

**Design.** GitHub Action on tag: run tests, build a universal binary, attach a bottle to the release and add the `bottle do` block to the formula. Submit to homebrew-core once the tool has some users.

## v2.2: auto-detect sessions

**Problem.** A `claude` session started without `lidless` gets no protection.

**Design.**
- Optional `lidless watch` mode, run by the existing LaunchAgent: every 60 s list `claude` processes (`proc_listpids` + `proc_pidpath`), and create an *adopted* hold for each one not already wrapped.
- Adopted holds can't inject hooks (the process is already running), so idle detection falls back to the session transcript mtime under `~/.claude/projects/`.
- Opt-in via config `autoDetect: true`; off by default so v1 stays predictable.

**Open questions.** Should adopted holds respect the same idle timeout, or a longer one since the signal is weaker?

## v2.3: `lidless doctor`

One command that checks and explains:
- sudoers rule present, valid, and matches the current username
- LaunchAgent loaded and pointing at an existing binary
- stale `SleepDisabled 1` with no live holds
- Claude Code version supports `--settings` hooks
- battery health and current thermal state

Each failure prints the exact command that fixes it.

## Later / maybe

- **Menu bar indicator**: a tiny status item showing hold count. This would need an app bundle, so only if the CLI proves insufficient.
- **Schedule windows**: `"allowedHours": "22:00-07:00"` to only hold overnight.
- **Run-and-report**: email or ntfy a summary (duration, exit code, last lines of output) when `--sleep-after` jobs finish.
- **Linux support**: `systemd-inhibit --what=handle-lid-switch` covers most of it. A separate backend behind `PowerControl`.

## Not planned

- Bypassing safety cutoffs. Battery and thermal limits stay on; they can be tuned, not disabled.
- A privileged helper daemon. The narrow sudoers rule is simpler to audit and enough for a personal tool.
