# lidsomnia — roadmap

v1 (shipped 2026-11-08) is described in [spec.md](spec.md). This file tracks what comes next, roughly in priority order. Each item lists the problem it solves, the proposed design, and the open questions to settle before building it.

## v1.1: hardening and Homebrew (done)

| Item | Problem | Fix |
|---|---|---|
| Honest status when pmset fails | `lidsomnia status` showed `holding` even if `sudo pmset` was refused. | Hold records carry `effective`; status shows `NOT holding (sudo pmset failed…)`. |
| Instant re-acquire | After an idle release, a new prompt waited up to 30 s for the next tick. | The `busy` hook sends `SIGUSR1` to the wrapper (`LIDSOMNIA_PID`), which re-evaluates immediately. |
| Strict argument parsing | `lidsomnia setup -S` silently ignored `-S`. | Unknown flags and arguments are usage errors (exit 2). |
| Watchdog follows installs | The LaunchAgent pointed at whichever binary ran `setup`. | `make install` re-runs `lidsomnia setup --agent-only`; the binary path is no longer symlink-resolved, so Homebrew's stable `/opt/homebrew/bin/lidsomnia` survives upgrades. |
| Homebrew | Install meant cloning and `make install`. | `brew install vitkon/tap/lidsomnia`. Source-build formula from the tagged tarball, published by `scripts/release.sh <version>`. |
| `--version` | No way to tell which build is installed. | `lidsomnia --version`. |

Remote Control phone prompts were verified to fire the hooks, so no fallback was needed.

## v2.0: phone alerts (done)

ntfy and webhook alerts for `lowBattery`, `thermal`, `idle` and `finished` (jobs of 5+ minutes), sent before the Mac is allowed to sleep. `lidsomnia test-alert` checks the wiring. The open question about `finished` defaults was settled with `finishedMinMinutes: 5`. Details in [spec.md](spec.md#phone-alerts-v20).

## v2.0.1: Homebrew bottles (done)

On a `v*` tag, GitHub Actions builds and tests bottles on `macos-15` (arm64) and `macos-15-intel`, attaches them to the GitHub release, merges the `bottle do` block into the formula and pushes it to `vitkon/homebrew-tap` (deploy key secret `TAP_DEPLOY_KEY`). A manual run with `publish=false` dry-runs the bottle build. `brew install` no longer needs Xcode on supported Macs. homebrew-core submission can come later once the tool has users.

## v2.0.2: auto-detect sessions (done)

Opt-in `autoDetect: true`: the watchdog adopts `claude` sessions not started through lidsomnia (including `claude --bg`), judging idleness by transcript writes with the same `idleTimeoutMinutes`. Details in [spec.md](spec.md#auto-detect-v202).

## v2.0.3: `lidsomnia doctor` (done)

Checks sudoers, the watchdog, PATH shadowing, a stale `SleepDisabled`, dead holds, config validity and typos, alert URLs, auto-detect wiring, Claude Code, and battery/thermal state. Each problem prints the exact command that fixes it. Details in [spec.md](spec.md#doctor-v203).

## v2.0.4: Codex support (done)

`lidsomnia codex …` plus auto-detect for Codex processes (CLI, `remote-control` daemon, VS Code extension), judged by Codex session-file writes because Codex requires per-hook approval. Also fixed auto-detect adopting agents' bundled tools (`ugrep`, `apply_patch`). Details in [spec.md](spec.md#codex-v204).

## v2.1.0: renamed from lidless (done)

Other apps already use the name lidless. Old installs keep working: Homebrew migrates the formula (`formula_renames.json` in the tap), a `lidless` symlink stays as an alias, and on first run lidsomnia moves `~/.lidless` to `~/.lidsomnia` (skipped while an old wrapper is still running) and swaps the `com.lidless.watchdog` agent for `com.lidsomnia.watchdog`. The old sudoers rule is the same rule and stays valid; `lidsomnia setup` replaces it, `uninstall` removes both.

## v2.2.0: phone control (done)

`idleSoon` warning five minutes before an idle release, with **Keep awake 1h** and **Sleep now** buttons (ntfy actions → control topic → watchdog). Tap confirmations; `test-alert` checks a button round trip. Details in [spec.md](spec.md#phone-control-v220).

## v2.2.0: `lidsomnia setup --codex-hooks` (done)

Opt-in busy/idle hooks in `~/.codex/hooks.json`, approved once with `/hooks`. Each hook finds its hold by walking up its parent processes, so it works for wrapped and auto-detected sessions alike. `doctor` shows whether they're approved and running. Details in [spec.md](spec.md#codex-hooks-v220-opt-in).

## v2.3.0: battery estimate (done)

`status` and `doctor` show the time left until the battery floor, scaled from macOS's time-to-empty estimate. A `batterySoon` warning goes to the phone once per discharge, `batteryWarningMinutes` (15) before the floor, with a **Sleep now** button that releases every hold. There's no keep-awake button: the floor is a safety limit. Details in [spec.md](spec.md#battery-estimate-v230).

## v2.4.0: bag mode and battery stretch (done)

A heat limit on battery temperature (45 °C, `hotSoon` warning 3 °C before with Sleep now, holds again 5 °C cooler), lid state in `status`/`doctor`, and Low Power Mode while the lid is closed and something is held. The sudoers rule gains `pmset -b lowpowermode 0|1`; existing installs re-run `lidsomnia setup`. `doctor`'s sudoers check now looks for a passwordless entry instead of trusting `sudo -l <command>`. Details in [spec.md](spec.md#bag-mode-and-low-power-mode-v240).

## Next: run reports

When a job ends, the `finished` alert also says how long the Mac was held, how much battery it used, and whether it was released early and why.

## Later / maybe

- **Menu bar indicator**: a tiny status item showing hold count. This would need an app bundle, so only if the CLI proves insufficient.
- **Schedule windows**: `"allowedHours": "22:00-07:00"` to only hold overnight.
- **Run-and-report**: email or ntfy a summary (duration, exit code, last lines of output) when `--sleep-after` jobs finish.
- **Linux support**: `systemd-inhibit --what=handle-lid-switch` covers most of it. A separate backend behind `PowerControl`.

## Not planned

- Bypassing safety cutoffs. Battery and thermal limits stay on; they can be tuned, not disabled.
- A privileged helper daemon. The narrow sudoers rule is simpler to audit and enough for a personal tool.
