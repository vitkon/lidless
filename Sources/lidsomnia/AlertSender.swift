import Darwin
import Foundation
import LidsomniaCore

struct AlertResult {
    var channel: String
    var status: Int?
    var error: String?
    var ok: Bool { status.map { (200..<300).contains($0) } ?? false }
}

/// Sends alert requests and waits (bounded) for them, so an alert always leaves the
/// machine before lidsomnia lets it sleep.
enum AlertSender {
    static func send(_ requests: [URLRequest], timeout: TimeInterval = 6) -> [AlertResult] {
        guard !requests.isEmpty else { return [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var results = requests.map { AlertResult(channel: $0.url?.host ?? "?", status: nil, error: "timed out") }
        for (i, r) in requests.enumerated() {
            group.enter()
            URLSession.shared.dataTask(with: r) { _, response, error in
                lock.lock()
                results[i].status = (response as? HTTPURLResponse)?.statusCode
                results[i].error = error?.localizedDescription
                if results[i].status != nil && error == nil { results[i].error = nil }
                lock.unlock()
                group.leave()
            }.resume()
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    static func hostName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// Send an alert for a hold to every configured channel; failures go to stderr only.
func sendAlert(_ kind: AlertKind, record: HoldRecord, readings r: Readings, exitCode: Int32?, config: Config,
               until: Date? = nil) {
    guard config.alerts.isConfigured else { return }
    let event = AlertEvent(
        kind: kind, host: AlertSender.hostName(), command: record.command, pid: record.pid,
        exitCode: exitCode, durationSeconds: Int(Date().timeIntervalSince(record.startedAt)),
        batteryPercent: r.batteryPercent, onBattery: r.onBattery, thermal: r.thermal, at: Date(),
        until: until, startedAt: record.startedAt)
    do {
        for res in AlertSender.send(try Alerts.requests(for: event, config: config)) where !res.ok {
            stderrLine("alert to \(res.channel) failed: \(res.status.map { "HTTP \($0)" } ?? res.error ?? "unknown")")
        }
    } catch {
        stderrLine("alert not sent: \(error)")
    }
}

func testAlertCommand(wait: Bool = true) -> Int32 {
    let paths = LidsomniaPaths.standard()
    let config = Config.load(from: paths.config)
    guard config.alerts.isConfigured else {
        stderrLine("""
        no alert channel configured. Add one to \(paths.config.path), e.g.:
          { "alerts": { "ntfyTopic": "pick-a-long-random-topic" } }
        then install the ntfy app on your phone and subscribe to that topic.
        """)
        return 1
    }
    let r = SystemReadings().read()
    let event = AlertEvent(kind: .test, host: AlertSender.hostName(), command: "lidsomnia test-alert",
                           pid: getpid(), exitCode: nil, durationSeconds: 0, batteryPercent: r.batteryPercent,
                           onBattery: r.onBattery, thermal: r.thermal, at: Date())
    let token = UUID().uuidString.prefix(8).lowercased()
    let sentAt = Int(Date().timeIntervalSince1970) - 5
    let buttons = Control.actions([("Test button", .ping(String(token)))], config: config.alerts)
    do {
        let results = AlertSender.send(try Alerts.requests(for: event, config: config, ntfyActions: buttons))
        for res in results {
            if res.ok {
                print("✓ \(res.channel) (\(res.status!))")
            } else {
                print("✗ \(res.channel): \(res.status.map { "HTTP \($0)" } ?? res.error ?? "failed")")
            }
        }
        guard results.allSatisfy(\.ok) else { return 1 }
        guard !buttons.isEmpty, wait else { return 0 }
        print("Tap \"Test button\" on the alert to check phone control (waiting up to 90 s, Ctrl-C to skip)…")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let msgs = PhoneControl.fetch(config.alerts, since: String(sentAt)) ?? []
            if msgs.contains(where: { ControlCommand.parse($0.body) == .ping(String(token)) }) {
                print("✓ button tap received: phone control works")
                return 0
            }
            Thread.sleep(forTimeInterval: 3)
        }
        print("✗ no tap received. Buttons post to ntfy topic \(Control.topic(config.alerts) ?? "?"); check the phone is online.")
        return 1
    } catch {
        stderrLine("\(error)")
        return 1
    }
}
