import Darwin
import Foundation

let usage = """
lidless — keep your Mac awake (even with the lid closed) while a job runs

usage:
  lidless [--sleep-after] <command> [args…]   run a command and hold the Mac awake while it's active
  lidless setup                               install the sudoers rule and watchdog (once)
  lidless uninstall                           remove them and re-enable sleep
  lidless status                              show holds, power and setup state
  lidless release                             drop all holds now (panic button)

`claude` sessions release the hold after 30 minutes idle (config: ~/.lidless/config.json).
"""

var args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case nil, "-h", "--help", "help":
    print(usage)
    exit(args.isEmpty ? 1 : 0)
case "setup": exit(setupCommand())
case "uninstall": exit(uninstallCommand())
case "status": exit(statusCommand())
case "release": exit(releaseCommand())
case "reap": exit(reapCommand())
case "hook": exit(hookCommand(args.count > 1 ? args[1] : ""))
default:
    var sleepAfter = false
    if args.first == "--sleep-after" {
        sleepAfter = true
        args.removeFirst()
    }
    if args.first == "--" { args.removeFirst() }
    guard !args.isEmpty else {
        print(usage)
        exit(1)
    }
    Wrapper(argv: args, sleepAfter: sleepAfter).run(argv: args)
}
