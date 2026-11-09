import Foundation

public enum CheckStatus: String, Sendable {
    case ok, warn, fail

    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        }
    }
}

public struct DoctorCheck: Equatable, Sendable {
    public var name: String
    public var status: CheckStatus
    public var detail: String
    /// The exact command that fixes (or verifies) it.
    public var fix: String?
}

/// Everything `lidsomnia doctor` looks at, gathered by the executable.
public struct DoctorFacts: Sendable {
    public var sudoAllowed: Bool
    public var agentPlistExists: Bool
    public var agentProgram: String?
    public var agentProgramExists: Bool
    public var agentLoaded: Bool
    public var agentLastExit: Int?
    public var runningBinary: String
    public var pathBinaries: [String]
    public var sleepDisabled: Bool?
    public var liveHeldHolds: Int
    public var deadHolds: Int
    public var configExists: Bool
    public var configError: String?
    public var unknownConfigKeys: [String]
    public var alertsError: String?
    public var claudeVersion: String?
    public var codexVersion: String? = nil
    /// Binary the installed Codex hooks run; nil when they aren't installed.
    public var codexHooksBinary: String? = nil
    public var codexHooksBinaryExists: Bool = true
    /// How long ago a Codex hook last ran; nil if never (not yet approved in `/hooks`).
    public var codexHooksLastRanAgo: TimeInterval? = nil
    public var readings: Readings
    public var config: Config

    public init(sudoAllowed: Bool, agentPlistExists: Bool, agentProgram: String?, agentProgramExists: Bool,
                agentLoaded: Bool, agentLastExit: Int?, runningBinary: String, pathBinaries: [String],
                sleepDisabled: Bool?, liveHeldHolds: Int, deadHolds: Int, configExists: Bool,
                configError: String?, unknownConfigKeys: [String], alertsError: String?,
                claudeVersion: String?, readings: Readings, config: Config) {
        self.sudoAllowed = sudoAllowed
        self.agentPlistExists = agentPlistExists
        self.agentProgram = agentProgram
        self.agentProgramExists = agentProgramExists
        self.agentLoaded = agentLoaded
        self.agentLastExit = agentLastExit
        self.runningBinary = runningBinary
        self.pathBinaries = pathBinaries
        self.sleepDisabled = sleepDisabled
        self.liveHeldHolds = liveHeldHolds
        self.deadHolds = deadHolds
        self.configExists = configExists
        self.configError = configError
        self.unknownConfigKeys = unknownConfigKeys
        self.alertsError = alertsError
        self.claudeVersion = claudeVersion
        self.readings = readings
        self.config = config
    }
}

public enum Doctor {
    static let configKeys: Set<String> = ["idleTimeoutMinutes", "batteryFloorPercent", "thermalLimit", "notify",
                                          "alerts", "autoDetect"]
    static let alertKeys: Set<String> = ["ntfyTopic", "ntfyServer", "ntfyToken", "webhookURL", "events",
                                         "finishedMinMinutes", "idleWarningMinutes", "batteryWarningMinutes",
                                         "phoneControl", "controlTopic"]

    /// Keys lidsomnia doesn't know (usually typos), as `key` or `alerts.key`, sorted.
    public static func unknownKeys(in data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out = obj.keys.filter { !configKeys.contains($0) }
        if let alerts = obj["alerts"] as? [String: Any] {
            out += alerts.keys.filter { !alertKeys.contains($0) }.map { "alerts.\($0)" }
        }
        return out.sorted()
    }

    public static func exitCode(_ checks: [DoctorCheck]) -> Int32 {
        checks.contains { $0.status == .fail } ? 1 : 0
    }

    public static func evaluate(_ f: DoctorFacts) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        func add(_ name: String, _ status: CheckStatus, _ detail: String, fix: String? = nil) {
            out.append(DoctorCheck(name: name, status: status, detail: detail, fix: fix))
        }

        add("sudoers", f.sudoAllowed ? .ok : .fail,
            f.sudoAllowed ? "pmset can be toggled without a password"
                          : "the sudoers rule is missing or doesn't match your user, so lidsomnia can't keep the Mac awake",
            fix: f.sudoAllowed ? nil : "lidsomnia setup")

        // Watchdog
        let agentFix = "lidsomnia setup --agent-only"
        if !f.agentPlistExists {
            add("watchdog", .fail, "not installed: nothing resets sleep if lidsomnia is killed", fix: agentFix)
        } else if !f.agentProgramExists {
            add("watchdog", .fail, "points at \(f.agentProgram ?? "?"), which no longer exists", fix: agentFix)
        } else if !f.agentLoaded {
            add("watchdog", .fail, "installed but not loaded in launchd", fix: agentFix)
        } else if let program = f.agentProgram, program != f.runningBinary {
            add("watchdog", .warn, "runs \(program), but you're running \(f.runningBinary)", fix: agentFix)
        } else if let code = f.agentLastExit, code != 0 {
            add("watchdog", .warn, "last run exited with code \(code); see ~/.lidsomnia/watchdog.log", fix: agentFix)
        } else {
            add("watchdog", .ok, "loaded, runs every 60 s")
        }

        let distinct = f.pathBinaries.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count > 1 {
            add("binary", .warn, "several lidsomnia binaries on PATH; \(distinct[0]) wins: \(distinct.joined(separator: ", "))",
                fix: "rm \(distinct.filter { $0 != f.runningBinary }.first ?? distinct[0])")
        } else {
            add("binary", .ok, f.runningBinary)
        }

        switch (f.sleepDisabled, f.liveHeldHolds) {
        case (nil, _):
            add("sleep flag", .warn, "couldn't read SleepDisabled from pmset")
        case (true?, 0):
            add("sleep flag", .fail, "SleepDisabled is 1 but nothing is holding it: the Mac will never sleep",
                fix: "lidsomnia release")
        case (true?, let n):
            add("sleep flag", .ok, "Mac held awake by \(n) hold\(n == 1 ? "" : "s")")
        case (false?, _):
            add("sleep flag", .ok, "normal (sleep allowed)")
        }

        if f.deadHolds > 0 {
            add("holds", .warn, "\(f.deadHolds) hold\(f.deadHolds == 1 ? "" : "s") left by processes that have exited",
                fix: "lidsomnia reap")
        }

        if let error = f.configError {
            add("config", .fail, "~/.lidsomnia/config.json is invalid, so defaults are used: \(error)",
                fix: "edit ~/.lidsomnia/config.json")
        } else if !f.unknownConfigKeys.isEmpty {
            add("config", .warn, "unknown keys (typos?) are ignored: \(f.unknownConfigKeys.joined(separator: ", "))",
                fix: "edit ~/.lidsomnia/config.json")
        } else {
            let c = f.config
            add("config", .ok, (f.configExists ? "" : "defaults: ")
                + "idle \(Int(c.idleTimeoutMinutes))m, battery floor \(c.batteryFloorPercent)%, thermal limit \(c.thermalLimit.rawValue)")
        }

        if let error = f.alertsError {
            add("alerts", .fail, error, fix: "edit ~/.lidsomnia/config.json")
        } else if f.config.alerts.isConfigured {
            add("alerts", .ok, f.config.alerts.channels.joined(separator: ", "), fix: "lidsomnia test-alert")
        } else {
            add("alerts", .ok, "off (optional: add alerts.ntfyTopic to get phone alerts)")
        }

        if f.config.autoDetect {
            add("auto-detect", f.agentLoaded ? .ok : .fail,
                f.agentLoaded ? "on" : "on, but the watchdog that runs it isn't loaded",
                fix: f.agentLoaded ? nil : agentFix)
        }

        switch (f.claudeVersion, f.codexVersion) {
        case (nil, nil):
            add("agents", .warn, "neither `claude` nor `codex` found on PATH (only needed for agent sessions)")
        default:
            if let v = f.claudeVersion { add("claude", .ok, v) }
            if let v = f.codexVersion { add("codex", .ok, v) }
        }

        if f.codexVersion != nil {
            let hooksFix = "lidsomnia setup --codex-hooks"
            if let bin = f.codexHooksBinary {
                if !f.codexHooksBinaryExists {
                    add("codex hooks", .fail, "run \(bin), which no longer exists", fix: hooksFix)
                } else if let ago = f.codexHooksLastRanAgo {
                    add("codex hooks", .ok, "approved and running (last ran \(Int(ago / 60))m ago)")
                } else {
                    add("codex hooks", .warn, "installed but haven't run yet: approve them once in Codex",
                        fix: "codex, then type /hooks and trust the lidsomnia hooks")
                }
            } else {
                add("codex hooks", .ok, "off: Codex idle time is judged from session files", fix: hooksFix)
            }
        }

        let r = f.readings
        let battery = r.batteryPercent.map { "\($0)%" } ?? "n/a"
        let lowBattery = r.onBattery && (r.batteryPercent ?? 100) <= f.config.batteryFloorPercent
        let hot = r.thermal >= f.config.thermalLimit
        let estimate = Battery.minutesToFloor(r, floor: f.config.batteryFloorPercent)
            .map { ", about \(Battery.format($0)) to the \(f.config.batteryFloorPercent)% floor" } ?? ""
        let summary = "\(r.onBattery ? "battery" : "AC"), \(battery)\(estimate), thermal \(r.thermal.rawValue)"
        if lowBattery || hot {
            add("power", .warn, summary + (lowBattery ? "; battery is at the floor, holds will be released"
                                                      : "; running hot, holds will be released"))
        } else {
            add("power", .ok, summary)
        }
        return out
    }
}
