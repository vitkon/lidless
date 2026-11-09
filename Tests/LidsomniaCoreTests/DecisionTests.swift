import Foundation
import Testing
@testable import LidsomniaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let plugged = Readings(onBattery: false, batteryPercent: 80, thermal: .nominal)

private func input(
    kind: HoldKind = .plain,
    activity: Activity? = nil,
    readings: Readings = plugged,
    config: Config = Config(),
    minutesAfterStart: Double = 0,
    manuallyReleased: Bool = false
) -> DecisionInput {
    DecisionInput(
        kind: kind,
        startedAt: t0,
        activity: activity,
        readings: readings,
        config: config,
        now: t0.addingTimeInterval(minutesAfterStart * 60),
        manuallyReleased: manuallyReleased
    )
}

@Suite struct DecisionTests {
    @Test func plainCommandIsHeldWhileRunning() {
        #expect(decide(input(minutesAfterStart: 600)) == Decision(held: true, reason: .active))
    }

    @Test func manualReleaseWins() {
        #expect(decide(input(manuallyReleased: true)) == Decision(held: false, reason: .manual))
    }

    @Test func lowBatteryOnBatteryReleases() {
        let r = Readings(onBattery: true, batteryPercent: 10, thermal: .nominal)
        #expect(decide(input(readings: r)) == Decision(held: false, reason: .lowBattery))
    }

    @Test func lowBatteryWhileChargingKeepsHolding() {
        let r = Readings(onBattery: false, batteryPercent: 5, thermal: .nominal)
        #expect(decide(input(readings: r)).held)
    }

    @Test func batteryAboveFloorKeepsHolding() {
        let r = Readings(onBattery: true, batteryPercent: 11, thermal: .nominal)
        #expect(decide(input(readings: r)).held)
    }

    @Test func unknownBatteryPercentKeepsHolding() {
        let r = Readings(onBattery: true, batteryPercent: nil, thermal: .nominal)
        #expect(decide(input(readings: r)).held)
    }

    @Test func thermalAtLimitReleases() {
        let r = Readings(onBattery: false, batteryPercent: 80, thermal: .serious)
        #expect(decide(input(readings: r)) == Decision(held: false, reason: .thermal))
    }

    @Test func thermalBelowLimitHolds() {
        let r = Readings(onBattery: false, batteryPercent: 80, thermal: .fair)
        #expect(decide(input(readings: r)).held)
    }

    @Test func thermalLimitIsConfigurable() {
        var c = Config()
        c.thermalLimit = .critical
        let r = Readings(onBattery: false, batteryPercent: 80, thermal: .serious)
        #expect(decide(input(readings: r, config: c)).held)
    }

    @Test func claudeWithoutActivityIsIdleSinceStart() {
        #expect(decide(input(kind: .claude, minutesAfterStart: 29)).held)
        #expect(decide(input(kind: .claude, minutesAfterStart: 30)) == Decision(held: false, reason: .idle))
    }

    @Test func claudeBusyIsHeldRegardlessOfAge() {
        let a = Activity(state: .busy, at: t0)
        #expect(decide(input(kind: .claude, activity: a, minutesAfterStart: 500)).held)
    }

    @Test func claudeIdleTimerStartsAtLastActivity() {
        let a = Activity(state: .idle, at: t0.addingTimeInterval(60 * 60))
        #expect(decide(input(kind: .claude, activity: a, minutesAfterStart: 89)).held)
        #expect(decide(input(kind: .claude, activity: a, minutesAfterStart: 90)) == Decision(held: false, reason: .idle))
    }

    @Test func idleTimeoutIsConfigurable() {
        var c = Config()
        c.idleTimeoutMinutes = 1
        #expect(!decide(input(kind: .claude, config: c, minutesAfterStart: 1)).held)
    }

    @Test func plainCommandsNeverGoIdle() {
        let a = Activity(state: .idle, at: t0)
        #expect(decide(input(kind: .plain, activity: a, minutesAfterStart: 600)).held)
    }

    @Test func precedenceManualThenBatteryThenThermalThenIdle() {
        let hot = Readings(onBattery: true, batteryPercent: 3, thermal: .critical)
        #expect(decide(input(kind: .claude, readings: hot, minutesAfterStart: 99, manuallyReleased: true)).reason == .manual)
        #expect(decide(input(kind: .claude, readings: hot, minutesAfterStart: 99)).reason == .lowBattery)
        let hotCharged = Readings(onBattery: false, batteryPercent: 3, thermal: .critical)
        #expect(decide(input(kind: .claude, readings: hotCharged, minutesAfterStart: 99)).reason == .thermal)
    }
}

@Suite struct ConfigTests {
    @Test func emptyJSONGivesDefaults() throws {
        let c = try Config.decode(Data("{}".utf8))
        #expect(c == Config())
        #expect(c.idleTimeoutMinutes == 30)
        #expect(c.batteryFloorPercent == 10)
        #expect(c.thermalLimit == .serious)
        #expect(c.notify)
    }

    @Test func partialJSONOverridesOnlyGivenKeys() throws {
        let c = try Config.decode(Data(#"{"idleTimeoutMinutes": 5, "thermalLimit": "critical"}"#.utf8))
        #expect(c.idleTimeoutMinutes == 5)
        #expect(c.thermalLimit == .critical)
        #expect(c.batteryFloorPercent == 10)
    }

    @Test func missingFileGivesDefaults() {
        let url = URL(fileURLWithPath: "/nonexistent/lidsomnia/config.json")
        #expect(Config.load(from: url) == Config())
    }

    @Test func thermalLevelsAreOrdered() {
        #expect(ThermalLevel.nominal < .fair)
        #expect(ThermalLevel.fair < .serious)
        #expect(ThermalLevel.serious < .critical)
    }
}
