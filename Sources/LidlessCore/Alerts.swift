import Foundation

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case lowBattery, thermal, idle, finished, test
}

/// `alerts` section of `~/.lidless/config.json`. Every key is optional.
public struct AlertConfig: Codable, Equatable, Sendable {
    public var ntfyTopic: String?
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyToken: String?
    public var webhookURL: String?
    public var events: [AlertKind] = [.lowBattery, .thermal, .idle, .finished]
    /// `finished` is only sent for jobs that ran at least this long.
    public var finishedMinMinutes: Double = 5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertConfig()
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic)
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        ntfyToken = try c.decodeIfPresent(String.self, forKey: .ntfyToken)
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL)
        events = try c.decodeIfPresent([AlertKind].self, forKey: .events) ?? d.events
        finishedMinMinutes = try c.decodeIfPresent(Double.self, forKey: .finishedMinMinutes) ?? d.finishedMinMinutes
    }

    var topic: String? { nonEmpty(ntfyTopic) }
    var webhook: String? { nonEmpty(webhookURL) }
    public var isConfigured: Bool { topic != nil || webhook != nil }

    /// Human-readable list of active channels, for `lidless status`.
    public var channels: [String] {
        var out: [String] = []
        if let t = topic { out.append("ntfy \(t)") }
        if webhook != nil { out.append("webhook") }
        return out
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// What gets sent. Also the JSON body of webhook posts (plus title/message).
public struct AlertEvent: Codable, Equatable, Sendable {
    public var kind: AlertKind
    public var host: String
    public var command: String
    public var pid: Int32
    public var exitCode: Int32?
    public var durationSeconds: Int
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var thermal: ThermalLevel
    public var at: Date

    public init(kind: AlertKind, host: String, command: String, pid: Int32, exitCode: Int32?,
                durationSeconds: Int, batteryPercent: Int?, onBattery: Bool, thermal: ThermalLevel, at: Date) {
        self.kind = kind
        self.host = host
        self.command = command
        self.pid = pid
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.thermal = thermal
        self.at = at
    }
}

public struct AlertMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// ntfy priority, 1 (min) … 5 (max).
    public var priority: Int
    /// ntfy tags; known emoji names render as icons.
    public var tags: [String]
}

public enum Alerts {
    /// A hold going from held to released for one of these reasons is worth telling the phone about.
    public static func kindForTransition(wasHeld: Bool, decision: Decision) -> AlertKind? {
        guard wasHeld, !decision.held else { return nil }
        switch decision.reason {
        case .lowBattery: return .lowBattery
        case .thermal: return .thermal
        case .idle: return .idle
        case .active, .manual: return nil
        }
    }

    public static func shouldSendFinished(duration: TimeInterval, config: AlertConfig) -> Bool {
        duration >= config.finishedMinMinutes * 60
    }

    public static func message(for e: AlertEvent, config: Config) -> AlertMessage {
        let job = e.command.count > 80 ? String(e.command.prefix(77)) + "…" : e.command
        switch e.kind {
        case .lowBattery:
            let pct = e.batteryPercent.map { "\($0)%" } ?? "low"
            return AlertMessage(
                title: "Battery low on \(e.host)",
                body: "Battery is at \(pct). The Mac will sleep now so your work can resume once it's plugged in. Job: \(job)",
                priority: 4, tags: ["battery"])
        case .thermal:
            return AlertMessage(
                title: "\(e.host) is running hot",
                body: "Thermal state is \(e.thermal.rawValue). The Mac may sleep until it cools down. Job: \(job)",
                priority: 4, tags: ["fire"])
        case .idle:
            let mins = Int(config.idleTimeoutMinutes)
            let first = (e.command.split(separator: " ").first.map(String.init) ?? "") as NSString
            let agent = ["claude": "Claude", "codex": "Codex"][first.lastPathComponent] ?? "Session"
            return AlertMessage(
                title: "\(agent) went idle on \(e.host)",
                body: "No activity for \(mins) minutes. The session is still running, but the Mac may sleep now. Send a prompt to keep it awake.",
                priority: 3, tags: ["zzz"])
        case .finished:
            let code = e.exitCode ?? 0
            let ran = "\(job) ran for \(formatDuration(e.durationSeconds))."
            return code == 0
                ? AlertMessage(title: "Job finished on \(e.host)", body: ran, priority: 3, tags: ["white_check_mark"])
                : AlertMessage(title: "Job failed (exit \(code)) on \(e.host)", body: ran, priority: 4, tags: ["x"])
        case .test:
            return AlertMessage(title: "lidless test alert",
                                body: "Alerts from \(e.host) are working.", priority: 3, tags: ["bell"])
        }
    }

    /// One request per configured channel; empty if the event kind is filtered out.
    /// `test` events ignore the filter.
    public static func requests(for e: AlertEvent, config: Config) throws -> [URLRequest] {
        let a = config.alerts
        guard e.kind == .test || a.events.contains(e.kind) else { return [] }
        let msg = message(for: e, config: config)
        var out: [URLRequest] = []

        if let topic = a.topic {
            let server = a.ntfyServer.hasSuffix("/") ? String(a.ntfyServer.dropLast()) : a.ntfyServer
            guard let url = URL(string: server), url.scheme?.hasPrefix("http") == true else {
                throw LidlessError.command("invalid alerts.ntfyServer: \(a.ntfyServer)")
            }
            var r = jsonPost(url, [
                "topic": topic, "title": msg.title, "message": msg.body,
                "priority": msg.priority, "tags": msg.tags,
            ])
            if let token = a.ntfyToken, !token.isEmpty {
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            out.append(r)
        }

        if let hook = a.webhook {
            guard let url = URL(string: hook), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                throw LidlessError.command("invalid alerts.webhookURL: \(hook)")
            }
            var body = (try? JSONSerialization.jsonObject(with: HoldStore.encoder.encode(e))) as? [String: Any] ?? [:]
            body["title"] = msg.title
            body["message"] = msg.body
            out.append(jsonPost(url, body))
        }
        return out
    }

    private static func jsonPost(_ url: URL, _ body: [String: Any]) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    static func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 1 { return "\(seconds)s" }
        return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m"
    }
}
