import Foundation
import Testing
@testable import LidsomniaCore

private let bin = "/opt/homebrew/bin/lidsomnia"
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func commands(_ root: [String: Any], _ event: String) -> [String] {
    let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

private func codexHold(pid: Int32, child: Int32? = nil, adopted: Bool = false, kind: HoldKind = .codex) -> HoldRecord {
    HoldRecord(pid: pid, childPid: child, command: "codex", kind: kind, startedAt: t0, held: true,
               reason: .active, adopted: adopted)
}

@Suite struct CodexHooksFileTests {
    @Test func installsBusyAndIdleHooks() {
        let root = CodexHooks.installing(into: [:], bin: bin)
        for e in CodexHooks.busyEvents { #expect(commands(root, e) == ["\(bin) hook codex busy"]) }
        for e in CodexHooks.idleEvents { #expect(commands(root, e) == ["\(bin) hook codex idle"]) }
        #expect(CodexHooks.installedBinary(in: root) == bin)
    }

    @Test func keepsOtherHooksAndIsIdempotent() {
        let mine: [String: Any] = ["description": "mine", "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
        ]]
        let twice = CodexHooks.installing(into: CodexHooks.installing(into: mine, bin: bin), bin: bin)
        #expect(commands(twice, "Stop") == ["say done", "\(bin) hook codex idle"])
        #expect(twice["description"] as? String == "mine")

        let removed = CodexHooks.removing(from: twice)
        #expect(commands(removed, "Stop") == ["say done"])
        #expect(commands(removed, "PreToolUse").isEmpty)
        #expect(CodexHooks.installedBinary(in: removed) == nil)
    }

    @Test func movingTheBinaryReplacesTheHooks() {
        let root = CodexHooks.installing(into: CodexHooks.installing(into: [:], bin: "/old/lidsomnia"), bin: bin)
        #expect(commands(root, "Stop") == ["\(bin) hook codex idle"])
    }

    @Test func quotesPathsWithSpaces() {
        #expect(CodexHooks.command(bin: "/Users/me/my bin/lidsomnia", state: .idle) == "'/Users/me/my bin/lidsomnia' hook codex idle")
        let root = CodexHooks.installing(into: [:], bin: "/Users/me/my bin/lidsomnia")
        #expect(CodexHooks.installedBinary(in: root) == "/Users/me/my bin/lidsomnia")
    }
}

@Suite struct CodexHookMappingTests {
    @Test func findsWrappedHoldThroughItsCodexChild() {
        let holds = [codexHold(pid: 100, child: 101)]
        // hook ← sh ← codex(101) ← lidsomnia(100)
        #expect(CodexHooks.hold(forAncestors: [300, 200, 101, 100], holds: holds)?.pid == 100)
    }

    @Test func findsAdoptedHoldByItsOwnPid() {
        let holds = [codexHold(pid: 101, adopted: true)]
        #expect(CodexHooks.hold(forAncestors: [300, 101, 1], holds: holds)?.pid == 101)
    }

    @Test func ignoresUnrelatedAndNonCodexHolds() {
        let holds = [codexHold(pid: 100, child: 101), codexHold(pid: 500, child: 501, kind: .claude)]
        #expect(CodexHooks.hold(forAncestors: [300, 501, 500], holds: holds) == nil)
        #expect(CodexHooks.hold(forAncestors: [300, 999], holds: holds) == nil)
    }
}

@Suite struct CodexActivityTests {
    @Test func busyHookWinsOverOldSessionWrites() {
        let busy = Activity(state: .busy, at: t0)
        #expect(CodexHooks.activity(hook: busy, lastWrite: t0.addingTimeInterval(-600), startedAt: t0) == busy)
    }

    @Test func idleTakesTheNewestSignal() {
        let idle = Activity(state: .idle, at: t0.addingTimeInterval(60))
        #expect(CodexHooks.activity(hook: idle, lastWrite: t0.addingTimeInterval(120), startedAt: t0)
                == Activity(state: .idle, at: t0.addingTimeInterval(120)))
        #expect(CodexHooks.activity(hook: nil, lastWrite: nil, startedAt: t0) == Activity(state: .idle, at: t0))
    }

    @Test func busyHookKeepsALongCommandHeld() {
        // The case session files miss: one long command, no writes for 40 minutes.
        let input = DecisionInput(kind: .codex, startedAt: t0,
                                  activity: CodexHooks.activity(hook: Activity(state: .busy, at: t0), lastWrite: t0, startedAt: t0),
                                  readings: Readings(onBattery: true, batteryPercent: 80, thermal: .nominal),
                                  config: Config(), now: t0.addingTimeInterval(40 * 60), manuallyReleased: false)
        #expect(decide(input).held)
    }
}

@Suite struct CodexHooksDoctorTests {
    private func facts() -> DoctorFacts {
        var f = DoctorFacts(
            sudoAllowed: true, agentPlistExists: true, agentProgram: bin, agentProgramExists: true,
            agentLoaded: true, agentLastExit: 0, runningBinary: bin, pathBinaries: [bin],
            sleepDisabled: false, liveHeldHolds: 0, deadHolds: 0, configExists: true, configError: nil,
            unknownConfigKeys: [], alertsError: nil, claudeVersion: nil,
            readings: Readings(onBattery: false, batteryPercent: 80, thermal: .nominal), config: Config())
        f.codexVersion = "codex-cli 0.167.0"
        return f
    }

    private func check(_ f: DoctorFacts) -> DoctorCheck? { Doctor.evaluate(f).first { $0.name == "codex hooks" } }

    @Test func offSuggestsSetup() {
        #expect(check(facts())?.status == .ok)
        #expect(check(facts())?.fix == "lidsomnia setup --codex-hooks")
    }

    @Test func installedButNeverRanWarnsToApprove() {
        var f = facts()
        f.codexHooksBinary = bin
        #expect(check(f)?.status == .warn)
        #expect(check(f)?.fix?.contains("/hooks") == true)
        f.codexHooksLastRanAgo = 120
        #expect(check(f)?.status == .ok)
        f.codexHooksBinaryExists = false
        #expect(check(f)?.status == .fail)
    }

    @Test func notShownWithoutCodex() {
        var f = facts()
        f.codexVersion = nil
        #expect(check(f) == nil)
    }
}
