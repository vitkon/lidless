import Foundation

public enum ThermalLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case nominal, fair, serious, critical

    var rank: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

public enum HoldKind: String, Codable, Sendable {
    /// Any command: active for as long as it runs.
    case plain
    /// A `claude` session: idle detection via hooks.
    case claude
    /// A `codex` session: idle detection via session (rollout) file writes.
    case codex
}

public enum ActivityState: String, Codable, Sendable {
    case busy, idle
}

/// Written by Claude Code hooks to `<pid>.activity`.
public struct Activity: Codable, Equatable, Sendable {
    public var state: ActivityState
    public var at: Date

    public init(state: ActivityState, at: Date) {
        self.state = state
        self.at = at
    }
}

public struct Readings: Equatable, Sendable {
    public var onBattery: Bool
    /// nil when the machine has no battery or it can't be read.
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(onBattery: Bool, batteryPercent: Int?, thermal: ThermalLevel) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

public enum HoldReason: String, Codable, Sendable {
    case active, idle, lowBattery, thermal, manual

    public var isSafety: Bool { self == .lowBattery || self == .thermal }
}

/// Written by the wrapper to `<pid>.json`.
public struct HoldRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var childPid: Int32?
    public var command: String
    public var kind: HoldKind
    public var startedAt: Date
    public var held: Bool
    public var reason: HoldReason
    /// False when the hold wants the Mac awake but `sudo pmset` was refused (setup missing).
    public var effective: Bool
    /// True for a `claude` session picked up by auto-detect; `pid` is then the claude process.
    public var adopted: Bool
    /// Working directory of an adopted session, used to find its transcripts.
    public var cwd: String?
    /// The idle release time an `idleSoon` warning was last sent for.
    public var idleWarnedFor: Date?

    public init(pid: Int32, childPid: Int32? = nil, command: String, kind: HoldKind,
                startedAt: Date, held: Bool, reason: HoldReason, effective: Bool = true,
                adopted: Bool = false, cwd: String? = nil) {
        self.pid = pid
        self.childPid = childPid
        self.command = command
        self.kind = kind
        self.startedAt = startedAt
        self.held = held
        self.reason = reason
        self.effective = effective
        self.adopted = adopted
        self.cwd = cwd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        childPid = try c.decodeIfPresent(Int32.self, forKey: .childPid)
        command = try c.decode(String.self, forKey: .command)
        kind = try c.decode(HoldKind.self, forKey: .kind)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        held = try c.decode(Bool.self, forKey: .held)
        reason = try c.decode(HoldReason.self, forKey: .reason)
        effective = try c.decodeIfPresent(Bool.self, forKey: .effective) ?? true
        adopted = try c.decodeIfPresent(Bool.self, forKey: .adopted) ?? false
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        idleWarnedFor = try c.decodeIfPresent(Date.self, forKey: .idleWarnedFor)
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var idleTimeoutMinutes: Double = 30
    public var batteryFloorPercent: Int = 10
    public var thermalLimit: ThermalLevel = .serious
    public var notify: Bool = true
    public var alerts = AlertConfig()
    /// Also keep the Mac awake for `claude` sessions not started through lidsomnia.
    public var autoDetect: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        idleTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutMinutes) ?? d.idleTimeoutMinutes
        batteryFloorPercent = try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? d.batteryFloorPercent
        thermalLimit = try c.decodeIfPresent(ThermalLevel.self, forKey: .thermalLimit) ?? d.thermalLimit
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
        alerts = try c.decodeIfPresent(AlertConfig.self, forKey: .alerts) ?? d.alerts
        autoDetect = try c.decodeIfPresent(Bool.self, forKey: .autoDetect) ?? d.autoDetect
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    /// Missing file → defaults. Malformed file → defaults plus a warning on stderr.
    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try decode(data)
        } catch {
            FileHandle.standardError.write(Data("lidsomnia: ignoring invalid \(url.path): \(error)\n".utf8))
            return Config()
        }
    }
}
