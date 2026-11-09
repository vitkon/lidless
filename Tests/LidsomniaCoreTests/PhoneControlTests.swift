import Foundation
import Testing
@testable import LidsomniaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let started = Date(timeIntervalSince1970: 999_000)

private func cfg(_ alerts: String = #"{"ntfyTopic": "mac-x7"}"#, idle: Int = 30) throws -> Config {
    try Config.decode(Data(#"{"idleTimeoutMinutes": \#(idle), "alerts": \#(alerts)}"#.utf8))
}

private func hold(_ pid: Int32 = 42, adopted: Bool = false) -> HoldRecord {
    HoldRecord(pid: pid, command: "claude --remote-control", kind: .claude, startedAt: started, held: true,
               reason: .active, adopted: adopted)
}

private func input(idleSince: Date, now: Date, config: Config, extendedUntil: Date? = nil) -> DecisionInput {
    DecisionInput(kind: .claude, startedAt: started, activity: Activity(state: .idle, at: idleSince),
                  readings: Readings(onBattery: true, batteryPercent: 80, thermal: .nominal),
                  config: config, now: now, manuallyReleased: false, extendedUntil: extendedUntil)
}

private func payload(_ r: URLRequest) throws -> [String: Any] {
    let data = try #require(r.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct ControlCommandTests {
    @Test func roundTrips() {
        for c: ControlCommand in [.extend(pid: 42, startedAt: 999_000, minutes: 60), .sleep(pid: 7, startedAt: 1), .ping("ab12")] {
            #expect(ControlCommand.parse(c.text) == c)
        }
    }

    @Test func rejectsJunkAndOverlongExtensions() {
        #expect(ControlCommand.parse("extend 42 999000 241") == nil)
        #expect(ControlCommand.parse("extend 42 999000 0") == nil)
        #expect(ControlCommand.parse("sleep 42") == nil)
        #expect(ControlCommand.parse("rm -rf /") == nil)
        #expect(ControlCommand.parse("") == nil)
    }
}

@Suite struct ControlTopicTests {
    @Test func defaultsToAlertTopicPlusSuffix() throws {
        #expect(Control.topic(try cfg().alerts) == "mac-x7-control")
        #expect(Control.topic(try cfg(#"{"ntfyTopic": "mac-x7", "controlTopic": "other"}"#).alerts) == "other")
    }

    @Test func offWithoutNtfyOrWhenDisabled() throws {
        #expect(Control.topic(Config().alerts) == nil)
        #expect(Control.topic(try cfg(#"{"webhookURL": "https://example.com/h"}"#).alerts) == nil)
        #expect(Control.topic(try cfg(#"{"ntfyTopic": "mac-x7", "phoneControl": false}"#).alerts) == nil)
    }

    @Test func pollURL() throws {
        let url = Control.pollURL(try cfg().alerts, since: "abc")
        #expect(url?.absoluteString == "https://ntfy.sh/mac-x7-control/json?poll=1&since=abc")
    }

    @Test func parsesNtfyStreamSkippingNonMessages() {
        let data = Data("""
        {"id":"k1","time":1000000,"event":"open","topic":"t"}
        {"id":"m1","time":1000001,"event":"message","topic":"t","message":"sleep 42 999000"}
        not json
        {"id":"m2","time":1000002,"event":"message","topic":"t","message":"ping x"}
        """.utf8)
        #expect(Control.parseMessages(data) == [
            ControlMessage(id: "m1", time: Date(timeIntervalSince1970: 1_000_001), body: "sleep 42 999000"),
            ControlMessage(id: "m2", time: Date(timeIntervalSince1970: 1_000_002), body: "ping x"),
        ])
    }
}

@Suite struct ControlPlanTests {
    @Test func appliesFreshCommandsForMatchingHolds() {
        let msgs = [ControlMessage(id: "1", time: t0, body: "extend 42 999000 60"),
                    ControlMessage(id: "2", time: t0, body: "sleep 42 999000")]
        #expect(Control.plan(msgs, holds: [hold()], now: t0.addingTimeInterval(30)) == [
            .extend(pid: 42, until: t0.addingTimeInterval(30 + 3600)), .sleep(pid: 42),
        ])
    }

    @Test func ignoresStaleTapsAndReusedPids() {
        let stale = ControlMessage(id: "1", time: t0, body: "sleep 42 999000")
        #expect(Control.plan([stale], holds: [hold()], now: t0.addingTimeInterval(16 * 60)).isEmpty)
        let otherJob = ControlMessage(id: "2", time: t0, body: "sleep 42 123")
        #expect(Control.plan([otherJob], holds: [hold()], now: t0).isEmpty)
        let noHold = ControlMessage(id: "3", time: t0, body: "extend 9 999000 60")
        #expect(Control.plan([noHold], holds: [hold()], now: t0).isEmpty)
    }
}

@Suite struct IdleWarningTests {
    @Test func extensionPostponesIdleRelease() throws {
        let c = try cfg()
        let idleFor31 = input(idleSince: t0, now: t0.addingTimeInterval(31 * 60), config: c)
        #expect(decide(idleFor31).reason == .idle)
        var extended = idleFor31
        extended.extendedUntil = t0.addingTimeInterval(90 * 60)
        #expect(decide(extended) == Decision(held: true, reason: .active))
        #expect(idleReleaseAt(extended) == t0.addingTimeInterval(90 * 60))
    }

    @Test func safetyStillWinsOverExtension() throws {
        var i = input(idleSince: t0, now: t0, config: try cfg(), extendedUntil: t0.addingTimeInterval(3600))
        i.readings.batteryPercent = 5
        #expect(decide(i).reason == .lowBattery)
    }

    @Test func warnsOnceInTheLastFiveMinutes() throws {
        let c = try cfg()
        let early = input(idleSince: t0, now: t0.addingTimeInterval(24 * 60), config: c)
        #expect(Alerts.idleWarningDue(early, decision: decide(early), warnedFor: nil) == nil)
        let due = input(idleSince: t0, now: t0.addingTimeInterval(26 * 60), config: c)
        let at = t0.addingTimeInterval(30 * 60)
        #expect(Alerts.idleWarningDue(due, decision: decide(due), warnedFor: nil) == at)
        #expect(Alerts.idleWarningDue(due, decision: decide(due), warnedFor: at) == nil)
    }

    @Test func warnsAgainBeforeAnExtensionEnds() throws {
        let end = t0.addingTimeInterval(90 * 60)
        let i = input(idleSince: t0, now: end.addingTimeInterval(-60), config: try cfg(), extendedUntil: end)
        #expect(Alerts.idleWarningDue(i, decision: decide(i), warnedFor: t0.addingTimeInterval(30 * 60)) == end)
    }

    @Test func noWarningWhenOffOrBusy() throws {
        let off = input(idleSince: t0, now: t0.addingTimeInterval(26 * 60),
                        config: try cfg(#"{"ntfyTopic": "t", "idleWarningMinutes": 0}"#))
        #expect(Alerts.idleWarningDue(off, decision: decide(off), warnedFor: nil) == nil)
        var busy = input(idleSince: t0, now: t0.addingTimeInterval(26 * 60), config: try cfg())
        busy.activity = Activity(state: .busy, at: t0)
        #expect(Alerts.idleWarningDue(busy, decision: decide(busy), warnedFor: nil) == nil)
    }
}

@Suite struct IdleSoonAlertTests {
    private func event(_ kind: AlertKind) -> AlertEvent {
        AlertEvent(kind: kind, host: "Mac", command: "claude --remote-control", pid: 42, exitCode: nil,
                   durationSeconds: 0, batteryPercent: 80, onBattery: true, thermal: .nominal, at: t0,
                   until: t0.addingTimeInterval(5 * 60), startedAt: started)
    }

    @Test func idleSoonCarriesButtonsToTheControlTopic() throws {
        let c = try cfg(#"{"ntfyTopic": "mac-x7", "ntfyToken": "tk"}"#)
        #expect(Alerts.message(for: event(.idleSoon), config: c).title == "Claude idle on Mac: sleeping in 5 min")
        let req = try #require(Alerts.requests(for: event(.idleSoon), config: c).first)
        let body = try payload(req)
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.map { $0["label"] as? String } == ["Keep awake 1h", "Sleep now"])
        #expect(actions.map { $0["body"] as? String } == ["extend 42 999000 60", "sleep 42 999000"])
        #expect(actions.allSatisfy { $0["url"] as? String == "https://ntfy.sh/mac-x7-control" })
        #expect((actions[0]["headers"] as? [String: String])?["Authorization"] == "Bearer tk")
    }

    @Test func otherAlertsAndDisabledControlHaveNoButtons() throws {
        let idleReq = try #require(Alerts.requests(for: event(.idle), config: try cfg()).first)
        let idle = try payload(idleReq)
        #expect(idle["actions"] == nil)
        let off = try cfg(#"{"ntfyTopic": "mac-x7", "phoneControl": false}"#)
        let soonReq = try #require(Alerts.requests(for: event(.idleSoon), config: off).first)
        let soon = try payload(soonReq)
        #expect(soon["actions"] == nil)
        #expect(Alerts.message(for: event(.idleSoon), config: off).body.contains("Send a prompt"))
    }

    @Test func confirmationsIgnoreTheEventFilter() throws {
        let c = try cfg(#"{"ntfyTopic": "mac-x7", "events": ["finished"]}"#)
        #expect(try Alerts.requests(for: event(.extended), config: c).count == 1)
        #expect(try Alerts.requests(for: event(.sleeping), config: c).count == 1)
        #expect(try Alerts.requests(for: event(.released), config: c).count == 1)
        #expect(try Alerts.requests(for: event(.idleSoon), config: c).isEmpty)
    }
}

@Suite struct ReleaseOneTests {
    @Test func releasesOnlyThatHold() throws {
        let paths = LidsomniaPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("ls-\(UUID())"))
        try paths.ensure()
        let store = HoldStore(paths: paths)
        let power = FakePower()
        let probe = FakeProbe()
        probe.alive = [1, 2]
        let r = Reconciler(store: store, power: power, probe: probe, lockURL: paths.lock)
        try r.update(hold(1))
        try r.update(hold(2, adopted: true))
        try store.writeExtension(pid: 1, until: t0)

        #expect(try r.release(pid: 1).desired)       // adopted hold 2 still holds
        #expect(!store.exists(pid: 1))
        #expect(store.readExtension(pid: 1) == nil)
        #expect(try r.release(pid: 2).desired == false)
        #expect(try store.read(pid: 2)?.reason == .manual)  // kept, so it isn't re-adopted
        #expect(power.disabled == false)
    }
}
