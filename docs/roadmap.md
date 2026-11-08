# lidless — roadmap

v1 (shipped 2026-11-08) is described in [spec.md](spec.md). This file tracks what comes next, roughly in priority order. Each item lists the problem it solves, the proposed design, and the open questions to settle before building it.

## v1.1: hardening

Small fixes found while testing v1.

| Item | Problem | Fix |
|---|---|---|
| Honest status when pmset fails | `lidless status` shows `holding` even if `sudo pmset` was refused. | Store a `effective: Bool` in the hold record; status shows `not holding (run lidless setup)`. |
| Instant re-acquire | After an idle release, a new prompt waits up to 30 s for the next tick. | The `busy` hook sends `SIGUSR1` to the wrapper pid (from `LIDLESS_ACTIVITY_FILE`'s name), which triggers an immediate tick. |
| Strict argument parsing | `lidless setup -S` silently ignored `-S`. | Reject unknown flags on subcommands with a usage error. |
| Watchdog follows installs | The LaunchAgent points at whichever binary ran `setup` (could be `.build/`). | `make install` re-runs `lidless setup --agent-only` when the agent exists. |
| RC phone prompts | Unverified: do phone prompts fire `UserPromptSubmit`? | If not: treat `--remote-control` sessions as never idle, or watch the session transcript's mtime as a second activity signal. |

## v2.0: phone alerts (webhook)

**Problem.** With the lid shut you're on your phone, so a macOS notification saying "letting the Mac sleep: battery low" is never seen. You find out only when the RC session goes dark.

**Design.**
- New config keys: `webhookURL` and `webhookEvents` (default `["lowBattery", "thermal", "idle", "exited"]`).
- POST JSON `{event, reason, command, pid, battery, thermal, at}` with a 5 s timeout, fire-and-forget, from the wrapper.
- First-class shortcut for [ntfy.sh](https://ntfy.sh): `"ntfyTopic": "my-mac"` posts a plain-text message with title and priority headers, no JSON wrangling.
- `lidless test-alert` sends a sample event so you can check the wiring.

**Open questions.** Should `exited` (job finished) be on by default? It's the most useful signal for long builds, but noisy for short commands. A minimum run time (e.g. only for jobs longer than 5 min) might settle it.

## v2.1: Homebrew

**Problem.** Install currently means cloning and `make install`.

**Design.**
- Tap `vitkon/homebrew-tap`, formula builds from a tagged source tarball with `swift build -c release`.
- `post_install` caveat tells the user to run `lidless setup` (formulae can't write sudoers).
- GitHub Action on tag: run tests, build universal binary, update formula sha.

**Open questions.** Source build vs. prebuilt bottle. A source build needs Xcode or the Command Line Tools; a bottle needs CI signing to avoid Gatekeeper prompts.

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
