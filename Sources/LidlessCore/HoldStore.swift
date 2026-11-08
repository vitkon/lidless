import Foundation

public struct LidlessPaths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// `$LIDLESS_HOME` or `~/.lidless`.
    public static func standard() -> LidlessPaths {
        if let override = ProcessInfo.processInfo.environment["LIDLESS_HOME"], !override.isEmpty {
            return LidlessPaths(home: URL(fileURLWithPath: override))
        }
        return LidlessPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lidless"))
    }

    public var holds: URL { home.appendingPathComponent("holds") }
    public var lock: URL { home.appendingPathComponent("lock") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var watchdogLog: URL { home.appendingPathComponent("watchdog.log") }

    public func ensure() throws {
        try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
    }
}

/// Hold files in `~/.lidless/holds/`: `<pid>.json` (wrapper-owned) and `<pid>.activity` (hook-owned).
public struct HoldStore: Sendable {
    public let paths: LidlessPaths

    public init(paths: LidlessPaths) { self.paths = paths }

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
    }

    public func writeActivity(_ activity: Activity, to url: URL) throws {
        try Self.encoder.encode(activity).write(to: url, options: .atomic)
    }

    public func readActivity(pid: Int32) -> Activity? {
        guard let data = try? Data(contentsOf: activityURL(pid: pid)) else { return nil }
        return try? Self.decoder.decode(Activity.self, from: data)
    }
}
