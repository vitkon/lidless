import Foundation
import Testing
@testable import LidsomniaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func warm(_ c: Double?, lid: Bool? = true, battery: Bool = true) -> Readings {
    Readings(onBattery: battery, batteryPercent: 60, thermal: .nominal, batteryTempC: c, lidClosed: lid)
}

private func input(_ r: Readings, previous: HoldReason? = nil) -> DecisionInput {
    DecisionInput(kind: .plain, startedAt: t0, activity: nil, readings: r, config: Config(), now: t0,
                  manuallyReleased: false, previousReason: previous)
}

@Suite struct HeatDecisionTests {
    @Test func releasesAtTheLimitAndHoldsBelow() {
        #expect(decide(input(warm(44.9))) == Decision(held: true, reason: .active))
        #expect(decide(input(warm(45))) == Decision(held: false, reason: .hot))
        #expect(decide(input(warm(nil))).held)  // no battery sensor: no heat rule
    }

    @Test func staysReleasedUntilItCools() {
        #expect(decide(input(warm(42), previous: .hot)).reason == .hot)
        #expect(decide(input(warm(40.1), previous: .hot)).reason == .hot)
        #expect(decide(input(warm(40), previous: .hot)).held)
        #expect(decide(input(warm(42), previous: .active)).held)
    }

    @Test func lowBatteryComesFirstAndLimitIsConfigurable() throws {
        var r = warm(50)
        r.batteryPercent = 5
        #expect(decide(input(r)).reason == .lowBattery)
        var i = input(warm(45))
        i.config = try Config.decode(Data(#"{"batteryTempLimitC": 50}"#.utf8))
        #expect(decide(i).held)
    }

    @Test func hotIsASafetyReleaseThatAlerts() {
        #expect(HoldReason.hot.isSafety)
        #expect(Alerts.kindForTransition(wasHeld: true, decision: Decision(held: false, reason: .hot)) == .hot)
    }
}

@Suite struct HeatWarningTests {
    @Test func warnsOnceInTheThreeDegreesBelowTheLimit() {
        let c = Config()
        #expect(!Heat.warningDue(warm(41.9), config: c, holding: true, alreadyWarned: false))
        #expect(Heat.warningDue(warm(42), config: c, holding: true, alreadyWarned: false))
        #expect(!Heat.warningDue(warm(43), config: c, holding: true, alreadyWarned: true))
        #expect(!Heat.warningDue(warm(43), config: c, holding: false, alreadyWarned: false))
        #expect(!Heat.warningDue(warm(45), config: c, holding: true, alreadyWarned: false))  // the release alert covers it
    }

    @Test func rearmsOnceCooledOrNothingHeld() {
        let c = Config()
        #expect(Heat.shouldRearm(warm(40), config: c, holding: true))
        #expect(!Heat.shouldRearm(warm(41), config: c, holding: true))
        #expect(Heat.shouldRearm(warm(44), config: c, holding: false))
    }
}

@Suite struct HeatAlertTests {
    private func event(_ kind: AlertKind, temp: Double, lid: Bool) -> AlertEvent {
        AlertEvent(kind: kind, host: "Mac", command: "claude --remote-control", pid: 42, exitCode: nil,
                   durationSeconds: 0, batteryPercent: 60, onBattery: true, thermal: .nominal, at: t0,
                   batteryTempC: temp, lidClosed: lid)
    }

    @Test func warningMentionsTheBagAndCarriesSleepNow() throws {
        let c = try Config.decode(Data(#"{"alerts": {"ntfyTopic": "mac-x7"}}"#.utf8))
        let msg = Alerts.message(for: event(.hotSoon, temp: 42.6, lid: true), config: c)
        #expect(msg.title == "Mac is getting warm: battery at 43°C")
        #expect(msg.body.contains("in a bag"))
        #expect(msg.body.contains("sleep at 45°C"))
        #expect(!Alerts.message(for: event(.hotSoon, temp: 42.6, lid: false), config: c).body.contains("bag"))
        let req = try #require(Alerts.requests(for: event(.hotSoon, temp: 42.6, lid: true), config: c).first)
        let data = try #require(req.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try #require(body["actions"] as? [[String: Any]])
        #expect(actions.map { $0["body"] as? String } == ["sleep-all"])
    }

    @Test func releaseSaysWhenItHoldsAgain() {
        let msg = Alerts.message(for: event(.hot, temp: 45.2, lid: true), config: Config())
        #expect(msg.title == "Mac is too hot: battery at 45°C")
        #expect(msg.body.contains("below 40°C"))
    }

    @Test func onByDefault() {
        #expect(AlertConfig().events.contains(.hotSoon))
        #expect(AlertConfig().events.contains(.hot))
    }
}

@Suite struct LowPowerTests {
    @Test func wantedOnlyWithLidClosedAndSomethingHeld() throws {
        let c = Config()
        #expect(LowPower.wanted(config: c, readings: warm(30, lid: true), holding: true))
        #expect(!LowPower.wanted(config: c, readings: warm(30, lid: false), holding: true))
        #expect(!LowPower.wanted(config: c, readings: warm(30, lid: nil), holding: true))
        #expect(!LowPower.wanted(config: c, readings: warm(30, lid: true), holding: false))
        let off = try Config.decode(Data(#"{"lowPowerWhenClosed": false}"#.utf8))
        #expect(!LowPower.wanted(config: off, readings: warm(30, lid: true), holding: true))
    }

    @Test func turnsOnAndBackOffOnlyWhatItTurnedOn() {
        #expect(LowPower.plan(wanted: true, isOn: false, marker: nil) == (.turnOn, .on))
        #expect(LowPower.plan(wanted: true, isOn: true, marker: .on) == (.none, .on))
        #expect(LowPower.plan(wanted: false, isOn: true, marker: .on) == (.turnOff, nil))
    }

    @Test func leavesYourSettingAlone() {
        // Already on before lidsomnia: never touched, not even when the lid opens.
        #expect(LowPower.plan(wanted: true, isOn: true, marker: nil) == (.none, nil))
        #expect(LowPower.plan(wanted: false, isOn: true, marker: nil) == (.none, nil))
        // You switched it off while lidsomnia had it on: stays off.
        #expect(LowPower.plan(wanted: true, isOn: false, marker: .on) == (.none, .overridden))
        #expect(LowPower.plan(wanted: true, isOn: false, marker: .overridden) == (.none, .overridden))
        #expect(LowPower.plan(wanted: false, isOn: false, marker: .overridden) == (.none, nil))
    }
}

@Suite struct BagModeDoctorTests {
    private func facts(_ r: Readings) -> DoctorFacts {
        DoctorFacts(sudoAllowed: true, agentPlistExists: true, agentProgram: "/bin/l", agentProgramExists: true,
                    agentLoaded: true, agentLastExit: 0, runningBinary: "/bin/l", pathBinaries: ["/bin/l"],
                    sleepDisabled: false, liveHeldHolds: 0, deadHolds: 0, configExists: true, configError: nil,
                    unknownConfigKeys: [], alertsError: nil, claudeVersion: nil, readings: r, config: Config())
    }

    private func check(_ f: DoctorFacts, _ name: String) -> DoctorCheck? { Doctor.evaluate(f).first { $0.name == name } }

    @Test func powerShowsTemperatureAndLidAndWarnsWhenHot() {
        #expect(check(facts(warm(31)), "power")?.detail == "battery, 60%, 31°C, lid closed, thermal nominal")
        #expect(check(facts(warm(31)), "power")?.status == .ok)
        #expect(check(facts(warm(46)), "power")?.status == .warn)
    }

    @Test func oldSudoersRuleWarnsToRerunSetup() {
        var f = facts(warm(31))
        #expect(check(f, "low power")?.status == .ok)
        f.lowPowerAllowed = false
        #expect(check(f, "low power")?.status == .warn)
        #expect(check(f, "low power")?.fix == "lidsomnia setup")
        f.lowPowerSupported = false
        #expect(check(f, "low power") == nil)
    }

    @Test func newKeysAreKnown() {
        #expect(Doctor.unknownKeys(in: Data(#"{"batteryTempLimitC": 44, "lowPowerWhenClosed": false}"#.utf8)).isEmpty)
    }

    @Test func sudoersNeedsAPasswordlessEntry() {
        let listing = """
        User me may run the following commands on mac:
            (ALL) ALL
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
        """
        #expect(Sudoers.passwordless("/usr/bin/pmset -a disablesleep 0", in: listing))
        #expect(!Sudoers.passwordless("/usr/bin/pmset -b lowpowermode 1", in: listing))  // (ALL) ALL needs a password
        #expect(Sudoers.passwordless("/usr/bin/pmset -b lowpowermode 1", in: "    (ALL) NOPASSWD: ALL"))
        let wrapped = """
        User me may run the following commands on mac:
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset sleepnow,
                /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1
            (ALL) ALL
        """
        #expect(Sudoers.passwordless("/usr/bin/pmset -b lowpowermode 1", in: wrapped))
        #expect(!Sudoers.passwordless("/usr/bin/true", in: wrapped))
    }
}
