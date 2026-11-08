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
    return 0
}

func reapCommand() -> Int32 {
    let (reconciler, _) = makeReconciler()
    do {
        let r = try reconciler.reconcile()
        if !r.removed.isEmpty || r.changed {
            print("\(ISO8601DateFormatter().string(from: Date())) reaped \(r.removed) sleepDisabled=\(r.desired)")
        }
        return 0
    } catch {
        stderrLine("\(error)")
        return 1
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
    print("config         idle \(Int(config.idleTimeoutMinutes))m, battery floor \(config.batteryFloorPercent)%, thermal limit \(config.thermalLimit.rawValue)")

    let holds = store.list()
    if holds.isEmpty {
        print("holds          none")
        return 0
    }
    print("holds")
    let now = Date()
    for h in holds {
        let alive = probe.isLiveLidless(pid: h.pid)
        var line = "  [\(h.pid)] \(h.held ? "holding" : "released (\(h.reason.rawValue))")"
        if !alive { line += " — DEAD, will be reaped" }
        if h.kind == .claude {
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

func setupCommand() -> Int32 {
    let bin = selfExecutablePath()
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
        print("Installing \(sudoersPath) (sudo will ask for your password)…")
        let install = try shell("/usr/bin/sudo", ["/usr/bin/install", "-m", "0440", "-o", "root", "-g", "wheel",
                                                   tmp.path, sudoersPath], captureOutput: false)
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
        print("Removing \(sudoersPath) (sudo may ask for your password)…")
        let r = try? shell("/usr/bin/sudo", ["/bin/rm", "-f", sudoersPath], captureOutput: false)
        if r?.status == 0 { print("✓ sudoers rule removed") } else { ok = false }
    }
    return ok ? 0 : 1
}
