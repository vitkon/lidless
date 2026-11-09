import Darwin
import Foundation
import LidsomniaCore

let usage = """
lidsomnia \(lidsomniaVersion) — keep your Mac awake (even with the lid closed) while a job runs

usage:
  lidsomnia [--sleep-after] <command> [args…]   run a command and hold the Mac awake while it's active
  lidsomnia setup [--agent-only]                install the sudoers rule and watchdog (once)
  lidsomnia setup --codex-hooks                 add busy/idle hooks to Codex (approve once with /hooks)
  lidsomnia uninstall                           remove them and re-enable sleep
  lidsomnia status                              show holds, power and setup state
  lidsomnia release                             drop all holds now (panic button)
  lidsomnia test-alert                          send a test alert (and check its button) [--no-wait]
  lidsomnia doctor                              check the setup and show how to fix problems
  lidsomnia --version

`claude` sessions release the hold after 30 minutes idle (config: ~/.lidsomnia/config.json).
"""

func usageError(_ message: String) -> Never {
    stderrLine(message)
    FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
    exit(2)
}

/// Subcommands take no extra arguments unless listed in `allowed`.
func expectArgs(_ rest: [String], allowed: Set<String> = [], for command: String) {
    for a in rest where !allowed.contains(a) {
        usageError("unknown argument for `\(command)`: \(a)")
    }
}

/// Global so the wrapper is never deallocated while its run loop (dispatchMain) is going.
var activeWrapper: Wrapper?

var args = Array(CommandLine.arguments.dropFirst())
let rest = Array(args.dropFirst())

switch args.first {
case "hook", "-v", "--version", "version", "-h", "--help", "help", nil:
    break
default:
    migrateLegacyInstall()
    if invokedAsLegacyName && isatty(STDERR_FILENO) == 1 {
        stderrLine("lidless is now called lidsomnia; the `lidless` command still works but may go away later")
    }
}

switch args.first {
case nil:
    print(usage)
    exit(1)
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "-v", "--version", "version":
    print("lidsomnia \(lidsomniaVersion)")
    exit(0)
case "setup":
    expectArgs(rest, allowed: ["--agent-only", "--codex-hooks"], for: "setup")
    if rest.contains("--codex-hooks") { exit(installCodexHooksCommand()) }
    exit(setupCommand(agentOnly: rest.contains("--agent-only")))
case "uninstall":
    expectArgs(rest, for: "uninstall")
    exit(uninstallCommand())
case "status":
    expectArgs(rest, for: "status")
    exit(statusCommand())
case "release":
    expectArgs(rest, for: "release")
    exit(releaseCommand())
case "doctor":
    expectArgs(rest, for: "doctor")
    exit(doctorCommand())
case "test-alert":
    expectArgs(rest, allowed: ["--no-wait"], for: "test-alert")
    exit(testAlertCommand(wait: !rest.contains("--no-wait")))
case "reap":
    expectArgs(rest, for: "reap")
    exit(reapCommand())
case "hook":
    if rest.count == 2, rest[0] == "codex" {
        exit(ActivityState(rawValue: rest[1]).map(codexHookCommand) ?? 0)
    }
    guard rest.count == 1, rest[0] == "busy" || rest[0] == "idle" else { exit(0) }  // never break claude
    exit(hookCommand(rest[0]))
default:
    var sleepAfter = false
    if args.first == "--sleep-after" {
        sleepAfter = true
        args.removeFirst()
    }
    if args.first == "--" { args.removeFirst() }
    if let flag = args.first, flag.hasPrefix("-") {
        usageError("unknown option: \(flag)")
    }
    guard !args.isEmpty else { usageError("missing command to run") }
    let wrapper = Wrapper(argv: args, sleepAfter: sleepAfter)
    activeWrapper = wrapper
    wrapper.run(argv: args)
}
