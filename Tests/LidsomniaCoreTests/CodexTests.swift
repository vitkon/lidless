import Foundation
import Testing
@testable import LidsomniaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// Builds a fake ~/.codex/sessions tree.
private struct Sessions {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-sessions-\(UUID())")

    @discardableResult
    func add(_ name: String, day: String = "2026/11/08", cwd: String, modified: Date) throws -> URL {
        let dir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-\(name).jsonl")
        let meta = #"{"timestamp":"x","type":"session_meta","payload":{"id":"\#(name)","cwd":"\#(cwd)"}}"#
        try Data((meta + "\n" + #"{"type":"event"}"# + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }
}

@Suite struct CodexDetectionTests {
    @Test func codexBinariesAreDetected() {
        #expect(AutoDetect.agentKind(path: "/opt/homebrew/bin/codex", argv: ["codex"]) == .codex)
        #expect(AutoDetect.agentKind(
            path: "/Users/me/.vscode/extensions/openai.chatgpt-26.5-darwin-arm64/bin/macos-aarch64/codex",
            argv: ["codex", "app-server"]) == .codex)
        #expect(AutoDetect.agentKind(
            path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]) == .codex)
    }

    @Test func claudeStillDetectedAndOthersNot() {
        #expect(AutoDetect.agentKind(path: "/Users/me/.local/share/claude/versions/2.1.319", argv: ["claude"]) == .claude)
        #expect(AutoDetect.agentKind(path: "/usr/bin/codesign", argv: ["codesign"]) == nil)
        #expect(AutoDetect.agentKind(path: "/opt/homebrew/bin/lidsomnia", argv: ["lidsomnia", "codex"]) == nil)
    }

    @Test func bundledToolsRunFromAgentBinariesAreNotSessions() {
        // Claude Code's native binary runs its bundled search tool as `ugrep`; Codex re-execs helpers.
        #expect(AutoDetect.agentKind(path: "/Users/me/.local/share/claude/versions/2.1.319",
                                     argv: ["ugrep", "-G", "pattern"]) == nil)
        #expect(AutoDetect.agentKind(path: "/opt/homebrew/bin/codex", argv: ["apply_patch"]) == nil)
    }

    @Test func pathDecidesWhenArgvIsUnreadable() {
        #expect(AutoDetect.agentKind(path: "/Users/me/.local/share/claude/versions/2.1.319", argv: []) == .claude)
        #expect(AutoDetect.agentKind(path: "/opt/homebrew/bin/codex", argv: []) == .codex)
    }

    @Test func wrapperKindFromCommand() {
        #expect(AutoDetect.wrapperKind("codex") == .codex)
        #expect(AutoDetect.wrapperKind("/opt/homebrew/bin/codex") == .codex)
        #expect(AutoDetect.wrapperKind("claude") == .claude)
        #expect(AutoDetect.wrapperKind("npm") == .plain)
    }

    @Test func codexHelperChildrenAreNotAdoptedSeparately() {
        let parent = ProcInfo(pid: 100, ppid: 1, path: "/opt/homebrew/bin/codex", argv: ["codex"], cwd: "/p")
        let child = ProcInfo(pid: 101, ppid: 100, path: "/opt/homebrew/bin/codex", argv: ["codex", "sandbox"], cwd: "/p")
        let p = AutoDetect.plan(processes: [parent, child], holds: [], enabled: true)
        #expect(p.adopt.map(\.pid) == [100])
    }
}

@Suite struct CodexTranscriptTests {
    @Test func prefersSessionsInTheSameDirectory() throws {
        let s = Sessions()
        try s.add("mine", cwd: "/Users/me/proj", modified: t0.addingTimeInterval(100))
        try s.add("other", cwd: "/Users/me/elsewhere", modified: t0.addingTimeInterval(500))
        let last = AutoDetect.latestCodexWrite(cwd: "/Users/me/proj", since: t0, sessionsDir: s.root)
        #expect(last == t0.addingTimeInterval(100))
    }

    @Test func fallsBackToAnySessionWhenNoDirectoryMatches() throws {
        let s = Sessions()
        try s.add("other", cwd: "/Users/me/elsewhere", modified: t0.addingTimeInterval(500))
        #expect(AutoDetect.latestCodexWrite(cwd: "/", since: t0, sessionsDir: s.root) == t0.addingTimeInterval(500))
        #expect(AutoDetect.latestCodexWrite(cwd: nil, since: t0, sessionsDir: s.root) == t0.addingTimeInterval(500))
    }

    @Test func ignoresSessionsNotWrittenSinceStart() throws {
        let s = Sessions()
        try s.add("old", cwd: "/Users/me/proj", modified: t0.addingTimeInterval(-60))
        #expect(AutoDetect.latestCodexWrite(cwd: "/Users/me/proj", since: t0, sessionsDir: s.root) == nil)
    }

    @Test func findsResumedSessionsInOlderDayFolders() throws {
        let s = Sessions()
        try s.add("resumed", day: "2025/03/01", cwd: "/Users/me/proj", modified: t0.addingTimeInterval(30))
        #expect(AutoDetect.latestCodexWrite(cwd: "/Users/me/proj", since: t0, sessionsDir: s.root) == t0.addingTimeInterval(30))
    }

    @Test func missingSessionsDirIsNil() {
        let none = URL(fileURLWithPath: "/nonexistent/codex/sessions")
        #expect(AutoDetect.latestCodexWrite(cwd: "/p", since: t0, sessionsDir: none) == nil)
    }
}

@Suite struct CodexDecisionTests {
    @Test func codexGoesIdleLikeClaude() {
        let r = Readings(onBattery: false, batteryPercent: 80, thermal: .nominal)
        let i = DecisionInput(kind: .codex, startedAt: t0, activity: Activity(state: .idle, at: t0), readings: r,
                              config: Config(), now: t0.addingTimeInterval(30 * 60), manuallyReleased: false)
        #expect(decide(i) == Decision(held: false, reason: .idle))
    }

    @Test func idleAlertNamesTheAgent() {
        let e = AlertEvent(kind: .idle, host: "Mac", command: "codex --full-auto", pid: 1, exitCode: nil,
                           durationSeconds: 0, batteryPercent: nil, onBattery: false, thermal: .nominal, at: t0)
        #expect(Alerts.message(for: e, config: Config()).title == "Codex went idle on Mac")
    }
}
