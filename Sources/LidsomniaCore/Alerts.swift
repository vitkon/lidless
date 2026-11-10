import Foundation

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case lowBattery, thermal, idle, finished, test
    /// Warning a few minutes before an idle release, with Keep awake / Sleep now buttons.
    case idleSoon
    /// Warning before a low-battery release, with a Sleep now button.
    case batterySoon
    /// Bag mode: warning before a heat release (Sleep now button), and the release itself.
    case hotSoon, hot
    /// Confirmations of a button tap; always sent, like `test`.
    case extended, sleeping, released
}

/// `alerts` section of `~/.lidsomnia/config.json`. Every key is optional.
public struct AlertConfig: Codable, Equatable, Sendable {
    public var ntfyTopic: String?
    public var ntfyServer: String = "https://ntfy.sh"
    public var ntfyToken: String?
    public var webhookURL: String?
    public var events: [AlertKind] = [.lowBattery, .batterySoon, .thermal, .hotSoon, .hot, .idleSoon, .idle, .finished]
    /// `finished` is only sent for jobs that ran at least this long.
    public var finishedMinMinutes: Double = 5
    /// `idleSoon` is sent this long before an idle release; 0 turns it off.
    public var idleWarningMinutes: Double = 5
    /// `batterySoon` is sent when the battery is estimated to reach the floor within this; 0 turns it off.
    public var batteryWarningMinutes: Double = 15
    /// Buttons on ntfy alerts that act on the Mac (via the control topic).
    public var phoneControl: Bool = true
    /// Topic the buttons post to; defaults to `<ntfyTopic>-control`.
    public var controlTopic: String?

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
        idleWarningMinutes = try c.decodeIfPresent(Double.self, forKey: .idleWarningMinutes) ?? d.idleWarningMinutes
        batteryWarningMinutes = try c.decodeIfPresent(Double.self, forKey: .batteryWarningMinutes) ?? d.batteryWarningMinutes
        phoneControl = try c.decodeIfPresent(Bool.self, forKey: .phoneControl) ?? d.phoneControl
        controlTopic = try c.decodeIfPresent(String.self, forKey: .controlTopic)
    }

    var topic: String? { nonEmpty(ntfyTopic) }
    var webhook: String? { nonEmpty(webhookURL) }
    public var isConfigured: Bool { topic != nil || webhook != nil }

    /// Human-readable list of active channels, for `lidsomnia status`.
    public var channels: [String] {
        var out: [String] = []
        if let t = topic { out.append("ntfy \(t)" + (Control.topic(self).map { " (buttons via \($0))" } ?? "")) }
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
    /// `idleSoon`: when the hold will be released. `extended`: when the extension ends.
    public var until: Date?
    /// Start of the hold, so buttons can name it exactly.
    public var startedAt: Date?
    public var batteryTempC: Double?
    public var lidClosed: Bool?

    public init(kind: AlertKind, host: String, command: String, pid: Int32, exitCode: Int32?,
                durationSeconds: Int, batteryPercent: Int?, onBattery: Bool, thermal: ThermalLevel, at: Date,
                until: Date? = nil, startedAt: Date? = nil, batteryTempC: Double? = nil, lidClosed: Bool? = nil) {
        self.batteryTempC = batteryTempC
        self.lidClosed = lidClosed
        self.until = until
        self.startedAt = startedAt
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
        case .hot: return .hot
        case .active, .manual: return nil
        }
    }

    /// When an "idle soon" warning is due, the release time it warns about (also what the
    /// caller stores as `idleWarnedFor`, so each release time is warned about once).
    public static func idleWarningDue(_ i: DecisionInput, decision: Decision, warnedFor: Date?) -> Date? {
        let lead = i.config.alerts.idleWarningMinutes * 60
        guard lead > 0, decision.held, let at = idleReleaseAt(i), at != warnedFor else { return nil }
        return i.now >= at.addingTimeInterval(-lead) && i.now < at ? at : nil
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
        case .batterySoon:
            let pct = e.batteryPercent.map { "\($0)%" } ?? "low"
            let left = e.until.map { "about \(formatDuration(Int($0.timeIntervalSince(e.at))))" } ?? "soon"
            let tail = Control.topic(config.alerts) != nil ? " Plug it in to keep going, or let it sleep now." : " Plug it in to keep going."
            return AlertMessage(
                title: "Battery low soon on \(e.host): \(left) left",
                body: "Battery is at \(pct). The Mac will sleep at \(config.batteryFloorPercent)%.\(tail)",
                priority: 4, tags: ["battery"])
        case .hotSoon:
            let temp = e.batteryTempC.map(Heat.format) ?? "warm"
            let bag = e.lidClosed == true ? "The lid is closed; if it's in a bag, give it some air. " : ""
            let tail = Control.topic(config.alerts) != nil ? " Or let it sleep now." : ""
            return AlertMessage(
                title: "\(e.host) is getting warm: battery at \(temp)",
                body: "\(bag)The Mac will sleep at \(Heat.format(config.batteryTempLimitC)) to protect the battery.\(tail)",
                priority: 4, tags: ["thermometer"])
        case .hot:
            let temp = e.batteryTempC.map(Heat.format) ?? "hot"
            return AlertMessage(
                title: "\(e.host) is too hot: battery at \(temp)",
                body: "Letting the Mac sleep to protect the battery. It holds again once the battery is below \(Heat.format(config.batteryTempLimitC - Heat.coolBy)). Job: \(job)",
                priority: 4, tags: ["fire"])
        case .thermal:
            return AlertMessage(
                title: "\(e.host) is running hot",
                body: "Thermal state is \(e.thermal.rawValue). The Mac may sleep until it cools down. Job: \(job)",
                priority: 4, tags: ["fire"])
        case .idleSoon:
            let left = max(1, Int(((e.until ?? e.at).timeIntervalSince(e.at) / 60).rounded()))
            let tail = Control.topic(config.alerts) != nil
                ? "Keep it awake for another hour, or let the Mac sleep now."
                : "Send a prompt to keep it awake."
            return AlertMessage(
                title: "\(agentName(e.command)) idle on \(e.host): sleeping in \(left) min",
                body: "No activity for a while. \(tail)", priority: 4, tags: ["hourglass"])
        case .extended:
            let left = Int(((e.until ?? e.at).timeIntervalSince(e.at) / 60).rounded())
            let clock = e.until.map { " (until \(shortTime($0)))" } ?? ""
            return AlertMessage(title: "Keeping \(e.host) awake",
                                body: "Another \(left) minutes\(clock) for \(job).", priority: 2, tags: ["coffee"])
        case .sleeping:
            return AlertMessage(title: "\(e.host) is going to sleep", body: "Released \(job).",
                                priority: 2, tags: ["zzz"])
        case .released:
            return AlertMessage(title: "Released \(job)", body: "\(e.host) stays awake for your other jobs.",
                                priority: 2, tags: ["ok_hand"])
        case .idle:
            let mins = Int(config.idleTimeoutMinutes)
            let agent = agentName(e.command)
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
            return AlertMessage(title: "lidsomnia test alert",
                                body: "Alerts from \(e.host) are working.", priority: 3, tags: ["bell"])
        }
    }

    /// One request per configured channel; empty if the event kind is filtered out.
    /// `test` events ignore the filter.
    /// `ntfyActions` replaces the buttons an event would otherwise get (used by `test-alert`).
    public static func requests(for e: AlertEvent, config: Config, ntfyActions: [[String: Any]]? = nil) throws -> [URLRequest] {
        let a = config.alerts
        let always: Set<AlertKind> = [.test, .extended, .sleeping, .released]
        guard always.contains(e.kind) || a.events.contains(e.kind) else { return [] }
        let msg = message(for: e, config: config)
        var out: [URLRequest] = []

        if let topic = a.topic {
            let server = a.ntfyServer.hasSuffix("/") ? String(a.ntfyServer.dropLast()) : a.ntfyServer
            guard let url = URL(string: server), url.scheme?.hasPrefix("http") == true else {
                throw LidsomniaError.command("invalid alerts.ntfyServer: \(a.ntfyServer)")
            }
            var payload: [String: Any] = [
                "topic": topic, "title": msg.title, "message": msg.body,
                "priority": msg.priority, "tags": msg.tags,
            ]
            var actions = ntfyActions ?? []
            if ntfyActions == nil, e.kind == .idleSoon, let s = e.startedAt {
                actions = Control.idleSoonActions(pid: e.pid, startedAt: s, config: a)
            }
            if ntfyActions == nil, e.kind == .batterySoon || e.kind == .hotSoon {
                actions = Control.actions([("Sleep now", .sleepAll)], config: a)
            }
            if !actions.isEmpty { payload["actions"] = actions }
            var r = jsonPost(url, payload)
            if let token = a.ntfyToken, !token.isEmpty {
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            out.append(r)
        }

        if let hook = a.webhook {
            guard let url = URL(string: hook), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                throw LidsomniaError.command("invalid alerts.webhookURL: \(hook)")
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

    static func agentName(_ command: String) -> String {
        let first = (command.split(separator: " ").first.map(String.init) ?? "") as NSString
        return ["claude": "Claude", "codex": "Codex"][first.lastPathComponent] ?? "Session"
    }

    static func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 1 { return "\(seconds)s" }
        return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m"
    }
}
