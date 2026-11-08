# lidless — implementation plan

See [spec.md](spec.md) for the design. Tasks are ordered so each one ends with passing tests or a runnable binary.

## 1. Scaffold
- `Package.swift`: library `LidlessCore`, executable `lidless`, test target `LidlessCoreTests` (Swift Testing). No dependencies; hand-rolled subcommand dispatch.
- `Makefile`: `build`, `test`, `install` (release build → `~/.local/bin/lidless`), `uninstall`.
- `git init`, `.gitignore`.

## 2. Core model + decision logic (TDD)
- `Config` (Codable, all optional, defaults), `ThermalLevel` (comparable), `Activity`, `Readings`, `HoldKind`, `HoldReason`.
- `Decision.decide(...)` — pure; tests for every rule and precedence.

## 3. Hold store + reconcile (TDD)
- `HoldStore` over a directory: atomic write/read of `<pid>.json` and `<pid>.activity`, list, delete.
- `Reconciler`: under `flock`, drop dead holds, compute desired `SleepDisabled`, call `PowerControl` only on change.
- Tests with temp dir + fake `PowerControl` / `ProcessProbe`.

## 4. Claude settings injection (TDD)
- Detect claude command, build hooks JSON, merge with existing `--settings` (file path or JSON string, `--settings x` and `--settings=x` forms).

## 5. System adapters (executable target)
- `PmsetPowerControl` (`pmset -g` parse, `sudo -n /usr/bin/pmset …`).
- `SystemReadings` (IOKit `IOPSCopyPowerSourcesInfo`, `ProcessInfo.thermalState`).
- `SystemProcessProbe` (`kill(pid,0)` + `proc_pidpath` basename == `lidless`).
- `OsascriptNotifier`.

## 6. Commands
- `run` (default): spawn child with `posix_spawn`, signal forwarding, 30 s monitor loop, exit code passthrough, `--sleep-after`.
- `hook busy|idle`, `status`, `release`, `reap`.
- `setup` / `uninstall`: sudoers via `visudo -cf` + `sudo install -m 0440`; LaunchAgent plist + `launchctl bootstrap/bootout gui/<uid>`.

## 7. Verify
- `swift test` green.
- Run the manual checklist in the spec (needs `lidless setup` by the user).
- Verify the RC `UserPromptSubmit` open question.
