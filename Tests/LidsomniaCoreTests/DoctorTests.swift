import Foundation
import Testing
@testable import LidsomniaCore

/// A fully healthy machine; each test breaks one thing.
private func healthy() -> DoctorFacts {
    DoctorFacts(
        sudoAllowed: true,
        agentPlistExists: true, agentProgram: "/opt/homebrew/bin/lidsomnia", agentProgramExists: true,
        agentLoaded: true, agentLastExit: 0,
        runningBinary: "/opt/homebrew/bin/lidsomnia", pathBinaries: ["/opt/homebrew/bin/lidsomnia"],
        sleepDisabled: false, liveHeldHolds: 0, deadHolds: 0,
        configExists: true, configError: nil, unknownConfigKeys: [], alertsError: nil,
        claudeVersion: "2.1.319 (Claude Code)",
        readings: Readings(onBattery: false, batteryPercent: 80, thermal: .nominal),
        config: Config())
}

private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
    checks.first { $0.name == name }
}

@Suite struct DoctorTests {
    @Test func healthyMachineHasNoProblems() {
        let checks = Doctor.evaluate(healthy())
        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(Doctor.exitCode(checks) == 0)
    }

    @Test func missingSudoersFailsWithSetupFix() {
        var f = healthy()
        f.sudoAllowed = false
        let c = check(Doctor.evaluate(f), "sudoers")
        #expect(c?.status == .fail)
        #expect(c?.fix == "lidsomnia setup")
        #expect(Doctor.exitCode(Doctor.evaluate(f)) == 1)
    }

    @Test func missingWatchdogFails() {
        var f = healthy()
        f.agentPlistExists = false
        f.agentLoaded = false
        let c = check(Doctor.evaluate(f), "watchdog")
        #expect(c?.status == .fail)
        #expect(c?.fix == "lidsomnia setup --agent-only")
    }

    @Test func watchdogPointingAtMissingBinaryFails() {
        var f = healthy()
        f.agentProgram = "/Users/me/.local/bin/lidsomnia"
        f.agentProgramExists = false
        #expect(check(Doctor.evaluate(f), "watchdog")?.status == .fail)
    }

    @Test func watchdogPointingElsewhereWarns() {
        var f = healthy()
        f.agentProgram = "/Users/me/.local/bin/lidsomnia"
        let c = check(Doctor.evaluate(f), "watchdog")
        #expect(c?.status == .warn)
        #expect(c?.fix == "lidsomnia setup --agent-only")
    }

    @Test func watchdogNotLoadedOrFailingWarns() {
        var f = healthy()
        f.agentLoaded = false
        #expect(check(Doctor.evaluate(f), "watchdog")?.status == .fail)
        f = healthy()
        f.agentLastExit = 1
        #expect(check(Doctor.evaluate(f), "watchdog")?.status == .warn)
    }

    @Test func shadowedBinaryWarns() {
        var f = healthy()
        f.pathBinaries = ["/Users/me/.local/bin/lidsomnia", "/opt/homebrew/bin/lidsomnia"]
        let c = check(Doctor.evaluate(f), "binary")
        #expect(c?.status == .warn)
        #expect(c?.detail.contains("/Users/me/.local/bin/lidsomnia") == true)
    }

    @Test func staleSleepFlagFailsWithReleaseFix() {
        var f = healthy()
        f.sleepDisabled = true
        let c = check(Doctor.evaluate(f), "sleep flag")
        #expect(c?.status == .fail)
        #expect(c?.fix == "lidsomnia release")
    }

    @Test func heldFlagWithLiveHoldIsFine() {
        var f = healthy()
        f.sleepDisabled = true
        f.liveHeldHolds = 1
        #expect(check(Doctor.evaluate(f), "sleep flag")?.status == .ok)
    }

    @Test func deadHoldsWarn() {
        var f = healthy()
        f.deadHolds = 2
        let c = check(Doctor.evaluate(f), "holds")
        #expect(c?.status == .warn)
        #expect(c?.fix == "lidsomnia reap")
    }

    @Test func badConfigFails() {
        var f = healthy()
        f.configError = "Unexpected character"
        #expect(check(Doctor.evaluate(f), "config")?.status == .fail)
    }

    @Test func unknownKeysWarn() {
        var f = healthy()
        f.unknownConfigKeys = ["idleTimout"]
        let c = check(Doctor.evaluate(f), "config")
        #expect(c?.status == .warn)
        #expect(c?.detail.contains("idleTimout") == true)
    }

    @Test func invalidAlertURLFails() {
        var f = healthy()
        f.alertsError = "invalid alerts.webhookURL: x"
        #expect(check(Doctor.evaluate(f), "alerts")?.status == .fail)
    }

    @Test func configuredAlertsSuggestTest() throws {
        var f = healthy()
        f.config = try Config.decode(Data(#"{"alerts":{"ntfyTopic":"t"}}"#.utf8))
        let c = check(Doctor.evaluate(f), "alerts")
        #expect(c?.status == .ok)
        #expect(c?.fix == "lidsomnia test-alert")
    }

    @Test func missingAgentsWarn() {
        var f = healthy()
        f.claudeVersion = nil
        #expect(check(Doctor.evaluate(f), "agents")?.status == .warn)
        f.codexVersion = "codex-cli 0.167.0"
        #expect(check(Doctor.evaluate(f), "agents") == nil)
        #expect(check(Doctor.evaluate(f), "codex")?.status == .ok)
    }

    @Test func autoDetectWithoutWatchdogFails() throws {
        var f = healthy()
        f.config = try Config.decode(Data(#"{"autoDetect":true}"#.utf8))
        f.agentLoaded = false
        let c = check(Doctor.evaluate(f), "auto-detect")
        #expect(c?.status == .fail)
    }

    @Test func powerLimitsWarnWhenTheyWouldRelease() {
        var f = healthy()
        f.readings = Readings(onBattery: true, batteryPercent: 8, thermal: .nominal)
        #expect(check(Doctor.evaluate(f), "power")?.status == .warn)
        f.readings = Readings(onBattery: false, batteryPercent: 80, thermal: .serious)
        #expect(check(Doctor.evaluate(f), "power")?.status == .warn)
    }

    @Test func unknownKeyDetection() {
        let data = Data(#"{"idleTimout": 5, "notify": true, "alerts": {"ntfyTopic": "t", "topic": "x"}}"#.utf8)
        #expect(Doctor.unknownKeys(in: data) == ["alerts.topic", "idleTimout"])
    }
}
