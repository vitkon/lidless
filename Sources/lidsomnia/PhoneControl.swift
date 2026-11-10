import Darwin
import Foundation
import LidsomniaCore

/// Reads the control topic that alert buttons post to.
enum PhoneControl {
    /// Messages since `since` (a message id or unix timestamp); nil on any network error.
    static func fetch(_ a: AlertConfig, since: String, timeout: TimeInterval = 5) -> [ControlMessage]? {
        guard let url = Control.pollURL(a, since: since) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let token = a.ntfyToken, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        var out: [ControlMessage]?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { out = Control.parseMessages(data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return out
    }

    static func cursorURL(_ paths: LidsomniaPaths) -> URL { paths.home.appendingPathComponent("control-since") }

    /// New messages since the last poll, advancing the saved cursor.
    static func poll(_ a: AlertConfig, paths: LidsomniaPaths, now: Date) -> [ControlMessage] {
        let saved = (try? String(contentsOf: cursorURL(paths), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let since = saved.flatMap { $0.isEmpty ? nil : $0 } ?? String(Int(now.timeIntervalSince1970 - Control.maxAge))
        guard let messages = fetch(a, since: since) else { return [] }
        if let last = messages.last?.id { try? Data(last.utf8).write(to: cursorURL(paths), options: .atomic) }
        return messages
    }
}

/// Watchdog step: act on button taps. Only polls while there are holds to act on.
func applyPhoneControl(reconciler: Reconciler, config: Config, paths: LidsomniaPaths, stamp: String) {
    let store = reconciler.store
    let holds = store.list()
    guard !holds.isEmpty, Control.topic(config.alerts) != nil else { return }
    let now = Date()
    let effects = Control.plan(PhoneControl.poll(config.alerts, paths: paths, now: now), holds: holds, now: now)
    let readings = SystemReadings().read()
    for effect in effects {
        switch effect {
        case let .extend(pid, until):
            guard let r = holds.first(where: { $0.pid == pid }) else { continue }
            do {
                try store.writeExtension(pid: pid, until: until)
                print("\(stamp) [\(pid)] phone: keep awake until \(ISO8601DateFormatter().string(from: until))")
                if !r.adopted { kill(pid, SIGUSR1) }  // wrapper re-evaluates now
                sendAlert(.extended, record: r, readings: readings, exitCode: nil, config: config, until: until)
            } catch {
                stderrLine("couldn't extend [\(pid)]: \(error)")
            }
        case let .sleep(pid):
            guard let r = holds.first(where: { $0.pid == pid }) else { continue }
            do {
                let result = try reconciler.release(pid: pid)
                print("\(stamp) [\(pid)] phone: released")
                if !r.adopted { kill(pid, SIGUSR1) }
                if result.desired {
                    sendAlert(.released, record: r, readings: readings, exitCode: nil, config: config)
                } else {
                    // Confirm first: once asleep, nothing leaves the Mac.
                    sendAlert(.sleeping, record: r, readings: readings, exitCode: nil, config: config)
                    applyLowPower(wanted: false, paths: paths, stamp: stamp)
                    try reconciler.power.sleepNow()
                }
            } catch {
                stderrLine("couldn't release [\(pid)]: \(error)")
            }
        case .sleepAll:
            do {
                try reconciler.releaseAll()
                print("\(stamp) phone: released all holds")
                for r in holds where !r.adopted { kill(r.pid, SIGUSR1) }
                let all = HoldRecord(pid: 0, command: "all jobs", kind: .plain, startedAt: now, held: false, reason: .manual)
                sendAlert(.sleeping, record: all, readings: readings, exitCode: nil, config: config)
                applyLowPower(wanted: false, paths: paths, stamp: stamp)
                try reconciler.power.sleepNow()
            } catch {
                stderrLine("couldn't release all: \(error)")
            }
        case .ping:
            break  // only `test-alert` cares
        }
    }
}
