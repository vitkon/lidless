import Foundation

/// Phone control: alert buttons POST one of these lines to the control topic; the watchdog polls
/// that topic and acts on them. Holds are named by pid *and* start time so a stale tap can never
/// touch a later job that reused the pid.
public enum ControlCommand: Equatable, Sendable {
    case extend(pid: Int32, startedAt: Int, minutes: Int)
    case sleep(pid: Int32, startedAt: Int)
    case ping(String)

    public static let maxExtendMinutes = 240

    public var text: String {
        switch self {
        case let .extend(pid, startedAt, minutes): return "extend \(pid) \(startedAt) \(minutes)"
        case let .sleep(pid, startedAt): return "sleep \(pid) \(startedAt)"
        case let .ping(token): return "ping \(token)"
        }
    }

    public static func parse(_ line: String) -> ControlCommand? {
        let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
        switch (w.first, w.count) {
        case ("extend", 4):
            guard let pid = Int32(w[1]), let s = Int(w[2]), let m = Int(w[3]), (1...maxExtendMinutes).contains(m)
            else { return nil }
            return .extend(pid: pid, startedAt: s, minutes: m)
        case ("sleep", 3):
            guard let pid = Int32(w[1]), let s = Int(w[2]) else { return nil }
            return .sleep(pid: pid, startedAt: s)
        case ("ping", 2):
            return .ping(w[1])
        default:
            return nil
        }
    }
}

/// One message from the control topic (`GET …/json?poll=1`, one JSON object per line).
public struct ControlMessage: Equatable, Sendable {
    public var id: String
    public var time: Date
    public var body: String

    public init(id: String, time: Date, body: String) {
        self.id = id
        self.time = time
        self.body = body
    }
}

public enum ControlEffect: Equatable, Sendable {
    case extend(pid: Int32, until: Date)
    case sleep(pid: Int32)
    case ping(String)
}

public enum Control {
    /// Taps older than this are ignored (the phone was offline, or the watchdog wasn't running).
    public static let maxAge: TimeInterval = 15 * 60
    public static let extendMinutes = 60

    /// The topic buttons post to, or nil when phone control is off or there's no ntfy topic.
    public static func topic(_ a: AlertConfig) -> String? {
        guard a.phoneControl, let t = a.topic else { return nil }
        if let c = a.controlTopic?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        return t + "-control"
    }

    static func server(_ a: AlertConfig) -> String {
        a.ntfyServer.hasSuffix("/") ? String(a.ntfyServer.dropLast()) : a.ntfyServer
    }

    /// ntfy `http` actions for an alert; the phone sends them straight to the control topic.
    public static func actions(_ commands: [(label: String, command: ControlCommand)], config a: AlertConfig) -> [[String: Any]] {
        guard let topic = topic(a) else { return [] }
        return commands.map { c in
            var action: [String: Any] = [
                "action": "http", "label": c.label, "url": "\(server(a))/\(topic)",
                "method": "POST", "body": c.command.text, "clear": true,
            ]
            if let token = a.ntfyToken, !token.isEmpty { action["headers"] = ["Authorization": "Bearer \(token)"] }
            return action
        }
    }

    /// Buttons for an "idle soon" warning about this hold.
    public static func idleSoonActions(pid: Int32, startedAt: Date, config a: AlertConfig) -> [[String: Any]] {
        let s = Int(startedAt.timeIntervalSince1970)
        return actions([("Keep awake 1h", .extend(pid: pid, startedAt: s, minutes: extendMinutes)),
                        ("Sleep now", .sleep(pid: pid, startedAt: s))], config: a)
    }

    /// `since` is a message id from the last poll, or a unix timestamp.
    public static func pollURL(_ a: AlertConfig, since: String) -> URL? {
        guard let topic = topic(a) else { return nil }
        var c = URLComponents(string: "\(server(a))/\(topic)/json")
        c?.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since)]
        return c?.url
    }

    public static func parseMessages(_ data: Data) -> [ControlMessage] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["event"] as? String == "message", let id = o["id"] as? String,
                  let time = (o["time"] as? NSNumber)?.doubleValue else { return nil }
            return ControlMessage(id: id, time: Date(timeIntervalSince1970: time), body: o["message"] as? String ?? "")
        }
    }

    /// What to do about a batch of messages, given the current holds. Unknown, stale or
    /// mismatched commands are dropped.
    public static func plan(_ messages: [ControlMessage], holds: [HoldRecord], now: Date) -> [ControlEffect] {
        func hold(_ pid: Int32, _ startedAt: Int) -> HoldRecord? {
            holds.first { $0.pid == pid && Int($0.startedAt.timeIntervalSince1970) == startedAt }
        }
        return messages.compactMap { m in
            guard now.timeIntervalSince(m.time) <= maxAge, let cmd = ControlCommand.parse(m.body) else { return nil }
            switch cmd {
            case let .extend(pid, s, minutes):
                return hold(pid, s).map { _ in .extend(pid: pid, until: now.addingTimeInterval(Double(minutes) * 60)) }
            case let .sleep(pid, s):
                return hold(pid, s).map { _ in .sleep(pid: pid) }
            case let .ping(token):
                return .ping(token)
            }
        }
    }
}
