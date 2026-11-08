import Darwin
import Foundation
import LidlessCore

let sudoersPath = "/etc/sudoers.d/lidless"
let agentLabel = "com.lidless.watchdog"

var agentPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
}

func makeReconciler() -> (Reconciler, LidlessPaths) {
    let paths = LidlessPaths.standard()
    try? paths.ensure()
    let r = Reconciler(store: HoldStore(paths: paths), power: PmsetPowerControl(),
                       probe: SystemProcessProbe(), lockURL: paths.lock)
    return (r, paths)
}

/// `lidless hook busy|idle` — called by Claude Code hooks. Must never fail or block claude.
func hookCommand(_ state: String) -> Int32 {
    guard let s = ActivityState(rawValue: state),
          let file = ProcessInfo.processInfo.environment["LIDLESS_ACTIVITY_FILE"], !file.isEmpty
    else { return 0 }
    let store = HoldStore(paths: LidlessPaths.standard())
    try? store.writeActivity(Activity(state: s, at: Date()), to: URL(fileURLWithPath: file))
    if let pidString = ProcessInfo.processInfo.environment["LIDLESS_PID"], let pid = Int32(pidString),
       shouldWakeWrapper(record: try? store.read(pid: pid), state: s),
       SystemProcessProbe().isLiveLidless(pid: pid) {
        kill(pid, SIGUSR1)  // re-acquire now instead of at the next 30 s tick
    }
    return 0
}

/// Run by the watchdog every 60 s: adopt/evaluate auto-detected claude sessions (if enabled),
/// drop dead holds, and make `SleepDisabled` match.
func reapCommand() -> Int32 {
    let (reconciler, paths) = makeReconciler()
    let store = reconciler.store
    let probe = SystemProcessProbe()
    let config = Config.load(from: paths.config)
    let stamp = ISO8601DateFormatter().string(from: Date())
    do {
        let holds = store.list()
        if config.autoDetect || holds.contains(where: \.adopted) {
            let plan = AutoDetect.plan(processes: config.autoDetect ? ProcessScanner.agentProcesses() : [],
                                       holds: holds, enabled: config.autoDetect)
            for pid in plan.drop {
                try reconciler.remove(pid: pid)
                print("\(stamp) auto-detect off: dropped [\(pid)]")
            }
            for p in plan.adopt {
                let command = p.argv.isEmpty ? (p.path as NSString).lastPathComponent : p.argv.joined(separator: " ")
                let kind = AutoDetect.agentKind(path: p.path, argv: p.argv) ?? .claude
                try reconciler.update(HoldRecord(pid: p.pid, command: command, kind: kind, startedAt: Date(),
                                                 held: false, reason: .active, adopted: true, cwd: p.cwd))
                print("\(stamp) adopted [\(p.pid)] \(command) in \(p.cwd ?? "?")")
            }
            try evaluateAdopted(reconciler: reconciler, probe: probe, config: config, stamp: stamp)
        }
        let r = try reconciler.reconcile()
        if !r.removed.isEmpty || r.changed {
            print("\(stamp) reaped \(r.removed) sleepDisabled=\(r.desired)")
        }
        return 0
    } catch {
        stderrLine("\(error)")
        return 1
    }
}

/// Adopted sessions have no hooks; their activity is the newest transcript/session-file write
/// (never earlier than adoption, so a newly adopted session gets a full idle window).
func lastAdoptedWrite(_ r: HoldRecord) -> Date? {
    r.kind == .codex
        ? AutoDetect.latestCodexWrite(cwd: r.cwd, since: r.startedAt)
        : r.cwd.flatMap { AutoDetect.latestTranscriptWrite(cwd: $0) }
}

func evaluateAdopted(reconciler: Reconciler, probe: ProcessProbe, config: Config, stamp: String) throws {
    let store = reconciler.store
    let readings = SystemReadings().read()
    for var r in store.list() where r.adopted && probe.isLive(r) {
        let lastWrite = lastAdoptedWrite(r) ?? r.startedAt
        let decision = decide(DecisionInput(
            kind: r.kind, startedAt: r.startedAt, activity: Activity(state: .idle, at: max(lastWrite, r.startedAt)),
            readings: readings, config: config, now: Date(),
            manuallyReleased: r.reason == .manual && !r.held))
        if let kind = Alerts.kindForTransition(wasHeld: r.held, decision: decision) {
            sendAlert(kind, record: r, readings: readings, exitCode: nil, config: config)
            if kind != .idle, config.notify { OsascriptNotifier().notify("Letting the Mac sleep (\(kind.rawValue)).") }
        }
        guard decision.held != r.held || decision.reason != r.reason || !r.effective else { continue }
        r.held = decision.held
        r.reason = decision.reason
        r.effective = true
        do {
            try reconciler.update(r)
        } catch {
            r.effective = false
            try? store.write(r)
            throw error
        }
        print("\(stamp) [\(r.pid)] \(r.held ? "holding" : "released (\(r.reason.rawValue))")")
    }
}

func releaseCommand() -> Int32 {
    let (reconciler, _) = makeReconciler()
    do {
        try reconciler.releaseAll()
        print("released all holds; sleep is enabled")
        return 0
    } catch {
        stderrLine("\(error)")
        return 1
    }
}

func statusCommand() -> Int32 {
    let (reconciler, paths) = makeReconciler()
    let store = reconciler.store
    let probe = SystemProcessProbe()
    let r = SystemReadings().read()
    let disabled = (try? PmsetPowerControl().sleepDisabled()).map { $0 ? "1 (Mac stays awake)" : "0 (normal)" } ?? "unknown"
    let battery = r.batteryPercent.map { "\($0)%" } ?? "n/a"
    let config = Config.load(from: paths.config)

    print("SleepDisabled  \(disabled)")
    print("power          \(r.onBattery ? "battery" : "AC"), \(battery), thermal \(r.thermal.rawValue)")
    print("setup          sudoers \(FileManager.default.fileExists(atPath: sudoersPath) ? "✓" : "✗ (run `lidless setup`)"), watchdog \(FileManager.default.fileExists(atPath: agentPlistURL.path) ? "✓" : "✗")")
    print("alerts         \(config.alerts.isConfigured ? config.alerts.channels.joined(separator: ", ") + " (" + config.alerts.events.map(\.rawValue).joined(separator: ", ") + ")" : "off (see `lidless test-alert`)")")
    print("config         idle \(Int(config.idleTimeoutMinutes))m, battery floor \(config.batteryFloorPercent)%, thermal limit \(config.thermalLimit.rawValue), auto-detect \(config.autoDetect ? "on" : "off")")

    let holds = store.list()
    if holds.isEmpty {
        print("holds          none")
        return 0
    }
    print("holds")
    let now = Date()
    for h in holds {
        let alive = probe.isLive(h)
        let state = !h.held ? "released (\(h.reason.rawValue))"
            : h.effective ? "holding" : "NOT holding (sudo pmset failed, run `lidless setup`)"
        var line = "  [\(h.pid)] \(state)"
        if !alive { line += " — DEAD, will be reaped" }
        if h.adopted || h.kind == .codex {
            let last = lastAdoptedWrite(h)
            line += ", \(h.kind.rawValue)\(h.adopted ? " (auto-detected)" : ""), last session write "
                + (last.map { minutes(now.timeIntervalSince($0)) + " ago" } ?? "none since start")
        } else if h.kind == .claude {
            if let a = store.readActivity(pid: h.pid) {
                line += ", claude \(a.state.rawValue) for \(minutes(now.timeIntervalSince(a.at)))"
            } else {
                line += ", claude idle since start (\(minutes(now.timeIntervalSince(h.startedAt))))"
            }
        }
        line += ", up \(minutes(now.timeIntervalSince(h.startedAt)))  \(h.command.prefix(60))"
        print(line)
    }
    return 0
}

private func minutes(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m"
}

// MARK: - setup / uninstall

func setupCommand(agentOnly: Bool = false) -> Int32 {
    let bin = selfExecutablePath()
    if agentOnly {
        do {
            try installAgent(bin: bin)
            print("✓ watchdog now runs \(bin) reap")
            return 0
        } catch {
            stderrLine("\(error)")
            return 1
        }
    }
    if bin.contains("/.build/") {
        stderrLine("warning: running from \(bin); the watchdog will point here. Prefer `make install` first.")
    }
    let user = NSUserName()
    let rule = """
    # Installed by lidless — allows toggling closed-lid sleep without a password.
    \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow

    """
    do {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lidless-sudoers-\(getpid())")
        try Data(rule.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let check = try shell("/usr/sbin/visudo", ["-cf", tmp.path])
        guard check.status == 0 else {
            stderrLine("generated sudoers rule failed validation: \(check.stdout)\(check.stderr)")
            return 1
        }
        print("Installing \(sudoersPath) (you'll be asked for your password)…")
        let install = try runAsAdmin(["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel",
                                      tmp.path, sudoersPath])
        guard install.status == 0 else {
            stderrLine("failed to install sudoers rule")
            return 1
        }
        try PmsetPowerControl().setSleepDisabled(false)  // proves the rule works
        print("✓ sudoers rule installed and working")

        try installAgent(bin: bin)
        print("✓ watchdog \(agentLabel) installed (runs `lidless reap` every 60s)")
        print("\nReady. Try: lidless claude --remote-control")
        return 0
    } catch {
        stderrLine("\(error)")
        return 1
    }
}

/// Run as root: `sudo` when there's a terminal to prompt on, otherwise the macOS admin password dialog.
func runAsAdmin(_ argv: [String]) throws -> ShellResult {
    if isatty(STDIN_FILENO) == 1 {
        return try shell("/usr/bin/sudo", argv, captureOutput: false)
    }
    func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
    let command = argv.map(sq).joined(separator: " ")
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return try shell("/usr/bin/osascript", [
        "-e", "do shell script \"\(escaped)\" with administrator privileges with prompt \"lidless needs to install a sudoers rule for pmset.\"",
    ])
}

func installAgent(bin: String) throws {
    let paths = LidlessPaths.standard()
    try paths.ensure()
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [bin, "reap"],
        "StartInterval": 60,
        "RunAtLoad": true,
        "StandardOutPath": paths.watchdogLog.path,
        "StandardErrorPath": paths.watchdogLog.path,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let domain = "gui/\(getuid())"
    _ = try? shell("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"])
    try data.write(to: agentPlistURL, options: .atomic)
    let r = try shell("/bin/launchctl", ["bootstrap", domain, agentPlistURL.path])
    guard r.status == 0 else { throw LidlessError.command("launchctl bootstrap failed: \(r.stderr)") }
}

func uninstallCommand() -> Int32 {
    var ok = true
    _ = try? shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
    try? FileManager.default.removeItem(at: agentPlistURL)
    print("✓ watchdog removed")

    let (reconciler, _) = makeReconciler()
    do {
        try reconciler.releaseAll()
        print("✓ holds released, sleep enabled")
    } catch {
        stderrLine("\(error)")
        ok = false
    }

    if FileManager.default.fileExists(atPath: sudoersPath) {
        print("Removing \(sudoersPath) (you may be asked for your password)…")
        let r = try? runAsAdmin(["/bin/rm", "-f", sudoersPath])
        if r?.status == 0 { print("✓ sudoers rule removed") } else { ok = false }
    }
    return ok ? 0 : 1
}
