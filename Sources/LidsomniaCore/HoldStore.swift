import Foundation

public struct LidsomniaPaths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// `$LIDSOMNIA_HOME` or `~/.lidsomnia`.
    public static func standard() -> LidsomniaPaths {
        if let override = ProcessInfo.processInfo.environment["LIDSOMNIA_HOME"], !override.isEmpty {
            return LidsomniaPaths(home: URL(fileURLWithPath: override))
        }
        return LidsomniaPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lidsomnia"))
    }

    public var holds: URL { home.appendingPathComponent("holds") }
    public var lock: URL { home.appendingPathComponent("lock") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var watchdogLog: URL { home.appendingPathComponent("watchdog.log") }

    public func ensure() throws {
        try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
    }
}

/// Hold files in `~/.lidsomnia/holds/`: `<pid>.json` (wrapper-owned) and `<pid>.activity` (hook-owned).
public struct HoldStore: Sendable {
    public let paths: LidsomniaPaths

    public init(paths: LidsomniaPaths) { self.paths = paths }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func holdURL(pid: Int32) -> URL { paths.holds.appendingPathComponent("\(pid).json") }
    public func activityURL(pid: Int32) -> URL { paths.holds.appendingPathComponent("\(pid).activity") }
    /// Written by the watchdog when a phone "Keep awake" tap arrives: the extension's end.
    public func extensionURL(pid: Int32) -> URL { paths.holds.appendingPathComponent("\(pid).extend") }

    public func writeExtension(pid: Int32, until: Date) throws {
        try Self.encoder.encode(["until": until]).write(to: extensionURL(pid: pid), options: .atomic)
    }

    public func readExtension(pid: Int32) -> Date? {
        guard let data = try? Data(contentsOf: extensionURL(pid: pid)) else { return nil }
        return (try? Self.decoder.decode([String: Date].self, from: data))?["until"]
    }

    public func write(_ record: HoldRecord) throws {
        try Self.encoder.encode(record).write(to: holdURL(pid: record.pid), options: .atomic)
    }

    public func read(pid: Int32) throws -> HoldRecord? {
        guard let data = try? Data(contentsOf: holdURL(pid: pid)) else { return nil }
        return try Self.decoder.decode(HoldRecord.self, from: data)
    }

    public func exists(pid: Int32) -> Bool {
        FileManager.default.fileExists(atPath: holdURL(pid: pid).path)
    }

    /// All readable hold records, sorted by pid. Corrupt files are skipped.
    public func list() -> [HoldRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.holds, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(HoldRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.pid < $1.pid }
    }

    public func remove(pid: Int32) {
        try? FileManager.default.removeItem(at: holdURL(pid: pid))
        try? FileManager.default.removeItem(at: activityURL(pid: pid))
        try? FileManager.default.removeItem(at: extensionURL(pid: pid))
    }

    public func writeActivity(_ activity: Activity, to url: URL) throws {
        try Self.encoder.encode(activity).write(to: url, options: .atomic)
    }

    public func readActivity(pid: Int32) -> Activity? {
        guard let data = try? Data(contentsOf: activityURL(pid: pid)) else { return nil }
        return try? Self.decoder.decode(Activity.self, from: data)
    }
}
