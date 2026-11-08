import Foundation
import LidlessCore

struct AlertResult {
    var channel: String
    var status: Int?
    var error: String?
    var ok: Bool { status.map { (200..<300).contains($0) } ?? false }
}

/// Sends alert requests and waits (bounded) for them, so an alert always leaves the
/// machine before lidless lets it sleep.
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

func testAlertCommand() -> Int32 {
    let paths = LidlessPaths.standard()
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
    let event = AlertEvent(kind: .test, host: AlertSender.hostName(), command: "lidless test-alert",
                           pid: getpid(), exitCode: nil, durationSeconds: 0, batteryPercent: r.batteryPercent,
                           onBattery: r.onBattery, thermal: r.thermal, at: Date())
    do {
        let results = AlertSender.send(try Alerts.requests(for: event, config: config))
        for res in results {
            if res.ok {
                print("✓ \(res.channel) (\(res.status!))")
            } else {
                print("✗ \(res.channel): \(res.status.map { "HTTP \($0)" } ?? res.error ?? "failed")")
            }
        }
        return results.allSatisfy(\.ok) ? 0 : 1
    } catch {
        stderrLine("\(error)")
        return 1
    }
}
