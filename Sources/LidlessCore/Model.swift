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

    public init(pid: Int32, childPid: Int32? = nil, command: String, kind: HoldKind,
                startedAt: Date, held: Bool, reason: HoldReason) {
        self.pid = pid
        self.childPid = childPid
        self.command = command
        self.kind = kind
        self.startedAt = startedAt
        self.held = held
        self.reason = reason
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var idleTimeoutMinutes: Double = 30
    public var batteryFloorPercent: Int = 10
    public var thermalLimit: ThermalLevel = .serious
    public var notify: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        idleTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutMinutes) ?? d.idleTimeoutMinutes
        batteryFloorPercent = try c.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? d.batteryFloorPercent
        thermalLimit = try c.decodeIfPresent(ThermalLevel.self, forKey: .thermalLimit) ?? d.thermalLimit
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
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
            FileHandle.standardError.write(Data("lidless: ignoring invalid \(url.path): \(error)\n".utf8))
            return Config()
        }
    }
}
