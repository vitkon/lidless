import Foundation
import Testing
@testable import LidsomniaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func onBattery(_ pct: Int, empty: Int?) -> Readings {
    Readings(onBattery: true, batteryPercent: pct, thermal: .nominal, minutesToEmpty: empty)
}

@Suite struct BatteryEstimateTests {
    @Test func scalesTimeToEmptyToTheFloor() {
        // 300 min to 0% from 60% → 5 min per point → 50 points to the 10% floor = 250 min.
        #expect(Battery.minutesToFloor(onBattery(60, empty: 300), floor: 10) == 250)
        #expect(Battery.minutesToFloor(onBattery(12, empty: 24), floor: 10) == 4)
    }

    @Test func noEstimateOnACAtTheFloorOrWhileCalculating() {
        #expect(Battery.minutesToFloor(Readings(onBattery: false, batteryPercent: 60, thermal: .nominal, minutesToEmpty: 300), floor: 10) == nil)
        #expect(Battery.minutesToFloor(onBattery(10, empty: 20), floor: 10) == nil)
        #expect(Battery.minutesToFloor(onBattery(60, empty: nil), floor: 10) == nil)
    }

    @Test func formats() {
        #expect(Battery.format(14) == "14m")
        #expect(Battery.format(130) == "2h10m")
    }
}

@Suite struct BatteryWarningTests {
    @Test func warnsOnceWhenWithinTheLead() {
        let c = Config()  // floor 10%, lead 15 min
        #expect(!Battery.warningDue(onBattery(60, empty: 300), config: c, holding: true, alreadyWarned: false))
        let close = onBattery(14, empty: 50)  // ~14 min to 10%
        #expect(Battery.warningDue(close, config: c, holding: true, alreadyWarned: false))
        #expect(!Battery.warningDue(close, config: c, holding: true, alreadyWarned: true))
        #expect(!Battery.warningDue(close, config: c, holding: false, alreadyWarned: false))
    }

    @Test func offWhenLeadIsZero() throws {
        let c = try Config.decode(Data(#"{"alerts": {"ntfyTopic": "t", "batteryWarningMinutes": 0}}"#.utf8))
        #expect(!Battery.warningDue(onBattery(14, empty: 50), config: c, holding: true, alreadyWarned: false))
    }

    @Test func rearmsOnACOrWithNothingHeld() {
        #expect(Battery.shouldRearm(Readings(onBattery: false, batteryPercent: 14, thermal: .nominal), holding: true))
        #expect(Battery.shouldRearm(onBattery(14, empty: 50), holding: false))
        #expect(!Battery.shouldRearm(onBattery(14, empty: 50), holding: true))
    }
}

@Suite struct BatterySoonAlertTests {
    private func event() -> AlertEvent {
        AlertEvent(kind: .batterySoon, host: "Mac", command: "2 jobs", pid: 42, exitCode: nil, durationSeconds: 0,
                   batteryPercent: 14, onBattery: true, thermal: .nominal, at: t0,
                   until: t0.addingTimeInterval(14 * 60), startedAt: t0)
    }

    @Test func messageAndSleepNowButton() throws {
        let c = try Config.decode(Data(#"{"alerts": {"ntfyTopic": "mac-x7"}}"#.utf8))
        let msg = Alerts.message(for: event(), config: c)
        #expect(msg.title == "Battery low soon on Mac: about 14m left")
        #expect(msg.body.contains("sleep at 10%"))
        let req = try #require(Alerts.requests(for: event(), config: c).first)
        let data = try #require(req.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.map { $0["label"] as? String } == ["Sleep now"])
        #expect(actions.map { $0["body"] as? String } == ["sleep-all"])
    }

    @Test func onByDefault() {
        #expect(AlertConfig().events.contains(.batterySoon))
    }
}

@Suite struct SleepAllControlTests {
    @Test func parsesAndPlans() {
        #expect(ControlCommand.parse("sleep-all") == .sleepAll)
        #expect(ControlCommand.parse(ControlCommand.sleepAll.text) == .sleepAll)
        let tap = ControlMessage(id: "1", time: t0, body: "sleep-all")
        let h = HoldRecord(pid: 1, command: "x", kind: .plain, startedAt: t0, held: true, reason: .active)
        #expect(Control.plan([tap], holds: [h], now: t0) == [.sleepAll])
        #expect(Control.plan([tap], holds: [], now: t0).isEmpty)
        #expect(Control.plan([tap], holds: [h], now: t0.addingTimeInterval(16 * 60)).isEmpty)
    }
}
