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

## v2.0: phone alerts (done)

ntfy and webhook alerts for `lowBattery`, `thermal`, `idle` and `finished` (jobs of 5+ minutes), sent before the Mac is allowed to sleep. `lidless test-alert` checks the wiring. The open question about `finished` defaults was settled with `finishedMinMinutes: 5`. Details in [spec.md](spec.md#phone-alerts-v20).

## v2.0.1: Homebrew bottles (done)

On a `v*` tag, GitHub Actions builds and tests bottles on `macos-15` (arm64) and `macos-15-intel`, attaches them to the GitHub release, merges the `bottle do` block into the formula and pushes it to `vitkon/homebrew-tap` (deploy key secret `TAP_DEPLOY_KEY`). A manual run with `publish=false` dry-runs the bottle build. `brew install` no longer needs Xcode on supported Macs. homebrew-core submission can come later once the tool has users.

## v2.0.2: auto-detect sessions (done)

Opt-in `autoDetect: true`: the watchdog adopts `claude` sessions not started through lidless (including `claude --bg`), judging idleness by transcript writes with the same `idleTimeoutMinutes`. Details in [spec.md](spec.md#auto-detect-v202).

## v2.0.3: `lidless doctor` (done)

Checks sudoers, the watchdog, PATH shadowing, a stale `SleepDisabled`, dead holds, config validity and typos, alert URLs, auto-detect wiring, Claude Code, and battery/thermal state. Each problem prints the exact command that fixes it. Details in [spec.md](spec.md#doctor-v203).

## v2.0.4: Codex support (done)

`lidless codex …` plus auto-detect for Codex processes (CLI, `remote-control` daemon, VS Code extension), judged by Codex session-file writes because Codex requires per-hook approval. Also fixed auto-detect adopting agents' bundled tools (`ugrep`, `apply_patch`). Details in [spec.md](spec.md#codex-v204).

## Next: `lidless setup --codex-hooks`

**Problem.** Session-file activity is less precise than hooks: a long single command with no session writes can be released mid-task.

**Design.** Opt-in setup step that adds lidless's busy/idle hooks to `~/.codex/hooks.json`; you approve them once in Codex's hook review. Hooks map to holds via `LIDLESS_ACTIVITY_FILE` for wrapped runs, and to adopted holds by session cwd otherwise.

## Later / maybe

- **Menu bar indicator**: a tiny status item showing hold count. This would need an app bundle, so only if the CLI proves insufficient.
- **Schedule windows**: `"allowedHours": "22:00-07:00"` to only hold overnight.
- **Run-and-report**: email or ntfy a summary (duration, exit code, last lines of output) when `--sleep-after` jobs finish.
- **Linux support**: `systemd-inhibit --what=handle-lid-switch` covers most of it. A separate backend behind `PowerControl`.

## Not planned

- Bypassing safety cutoffs. Battery and thermal limits stay on; they can be tuned, not disabled.
- A privileged helper daemon. The narrow sudoers rule is simpler to audit and enough for a personal tool.
