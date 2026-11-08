import Darwin
import Foundation

let usage = """
lidless \(lidlessVersion) — keep your Mac awake (even with the lid closed) while a job runs

usage:
  lidless [--sleep-after] <command> [args…]   run a command and hold the Mac awake while it's active
  lidless setup [--agent-only]                install the sudoers rule and watchdog (once)
  lidless uninstall                           remove them and re-enable sleep
  lidless status                              show holds, power and setup state
  lidless release                             drop all holds now (panic button)
  lidless test-alert                          send a test alert to your phone (ntfy / webhook)
  lidless --version

`claude` sessions release the hold after 30 minutes idle (config: ~/.lidless/config.json).
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

var args = Array(CommandLine.arguments.dropFirst())
let rest = Array(args.dropFirst())

switch args.first {
case nil:
    print(usage)
    exit(1)
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "-v", "--version", "version":
    print("lidless \(lidlessVersion)")
    exit(0)
case "setup":
    expectArgs(rest, allowed: ["--agent-only"], for: "setup")
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
case "test-alert":
    expectArgs(rest, for: "test-alert")
    exit(testAlertCommand())
case "reap":
    expectArgs(rest, for: "reap")
    exit(reapCommand())
case "hook":
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
    Wrapper(argv: args, sleepAfter: sleepAfter).run(argv: args)
}
