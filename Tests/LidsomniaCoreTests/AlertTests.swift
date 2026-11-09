import Foundation
import Testing
@testable import LidsomniaCore

private func event(_ kind: AlertKind, exitCode: Int32? = nil, duration: Int = 4320, battery: Int? = 9) -> AlertEvent {
    AlertEvent(kind: kind, host: "Test Mac", command: "claude --remote-control", pid: 42, exitCode: exitCode,
               durationSeconds: duration, batteryPercent: battery, onBattery: true, thermal: .nominal,
               at: Date(timeIntervalSince1970: 1_000))
}

private func json(_ r: URLRequest) throws -> [String: Any] {
    let data = try #require(r.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func config(_ alerts: String) throws -> Config {
    try Config.decode(Data(#"{"alerts": \#(alerts)}"#.utf8))
}

@Suite struct AlertConfigTests {
    @Test func alertsOffByDefault() {
        let c = Config()
        #expect(!c.alerts.isConfigured)
        #expect(c.alerts.events == [.lowBattery, .thermal, .idle, .finished])
        #expect(c.alerts.finishedMinMinutes == 5)
        #expect(c.alerts.ntfyServer == "https://ntfy.sh")
    }

    @Test func decodesPartialAlerts() throws {
        let c = try config(#"{"ntfyTopic": "my-mac", "events": ["finished"]}"#)
        #expect(c.alerts.isConfigured)
        #expect(c.alerts.ntfyTopic == "my-mac")
        #expect(c.alerts.events == [.finished])
        #expect(c.alerts.finishedMinMinutes == 5)
    }

    @Test func emptyTopicIsNotConfigured() throws {
        #expect(!(try config(#"{"ntfyTopic": "  "}"#)).alerts.isConfigured)
    }
}

@Suite struct AlertRuleTests {
    @Test func releaseTransitionsAlert() {
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: false, reason: .lowBattery)) == .lowBattery)
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: false, reason: .thermal)) == .thermal)
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: false, reason: .idle)) == .idle)
    }

    @Test func noAlertWithoutTransition() {
        #expect(Alerts.kindForTransition(wasHeld: false, decision: Decision(held: false, reason: .idle)) == nil)
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: true, reason: .active)) == nil)
    }

    @Test func manualReleaseDoesNotAlert() {
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: false, reason: .manual)) == nil)
    }

    @Test func finishedOnlyForLongJobs() {
        let a = AlertConfig()
        #expect(!Alerts.shouldSendFinished(duration: 299, config: a))
        #expect(Alerts.shouldSendFinished(duration: 300, config: a))
    }
}

@Suite struct AlertMessageTests {
    @Test func messagesNameTheProblem() {
        let c = Config()
        #expect(Alerts.message(for: event(.lowBattery), config: c).body.contains("9%"))
        #expect(Alerts.message(for: event(.lowBattery), config: c).priority == 4)
        #expect(Alerts.message(for: event(.idle), config: c).body.contains("30 minutes"))
        #expect(Alerts.message(for: event(.thermal), config: c).tags == ["fire"])
    }

    @Test func finishedReportsExitCodeAndDuration() {
        let ok = Alerts.message(for: event(.finished, exitCode: 0), config: Config())
        #expect(ok.title == "Job finished on Test Mac")
        #expect(ok.body.contains("1h12m"))
        let failed = Alerts.message(for: event(.finished, exitCode: 2), config: Config())
        #expect(failed.title == "Job failed (exit 2) on Test Mac")
        #expect(failed.priority == 4)
    }
}

@Suite struct AlertRequestTests {
    @Test func ntfyUsesJSONPublishWithTopic() throws {
        let c = try config(#"{"ntfyTopic": "my-mac"}"#)
        let reqs = try Alerts.requests(for: event(.idle), config: c)
        #expect(reqs.count == 1)
        #expect(reqs[0].url?.absoluteString == "https://ntfy.sh")
        #expect(reqs[0].httpMethod == "POST")
        let body = try json(reqs[0])
        #expect(body["topic"] as? String == "my-mac")
        #expect(body["title"] as? String == "Claude went idle on Test Mac")
        #expect(body["tags"] as? [String] == ["zzz"])
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func ntfyCustomServerAndToken() throws {
        let c = try config(#"{"ntfyTopic": "t", "ntfyServer": "https://ntfy.example.com/", "ntfyToken": "tk_1"}"#)
        let r = try #require(try Alerts.requests(for: event(.idle), config: c).first)
        #expect(r.url?.absoluteString == "https://ntfy.example.com")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tk_1")
    }

    @Test func webhookPostsEventJSON() throws {
        let c = try config(#"{"webhookURL": "https://hooks.example.com/x"}"#)
        let r = try #require(try Alerts.requests(for: event(.finished, exitCode: 0), config: c).first)
        #expect(r.url?.absoluteString == "https://hooks.example.com/x")
        let body = try json(r)
        #expect(body["kind"] as? String == "finished")
        #expect(body["exitCode"] as? Int == 0)
        #expect(body["title"] as? String == "Job finished on Test Mac")
    }

    @Test func bothChannels() throws {
        let c = try config(#"{"ntfyTopic": "t", "webhookURL": "https://hooks.example.com/x"}"#)
        #expect(try Alerts.requests(for: event(.idle), config: c).count == 2)
    }

    @Test func eventsFilterApplies() throws {
        let c = try config(#"{"ntfyTopic": "t", "events": ["finished"]}"#)
        #expect(try Alerts.requests(for: event(.idle), config: c).isEmpty)
    }

    @Test func testEventIgnoresFilter() throws {
        let c = try config(#"{"ntfyTopic": "t", "events": []}"#)
        #expect(try Alerts.requests(for: event(.test), config: c).count == 1)
    }

    @Test func badWebhookURLThrows() throws {
        let c = try config(#"{"webhookURL": "not a url"}"#)
        #expect(throws: LidsomniaError.self) { try Alerts.requests(for: event(.idle), config: c) }
    }
}
