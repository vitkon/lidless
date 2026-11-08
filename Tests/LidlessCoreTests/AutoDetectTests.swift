import Foundation
import Testing
@testable import LidlessCore

private func proc(_ pid: Int32, ppid: Int32 = 1, path: String = "/Users/me/.local/share/claude/versions/2.1.319",
                  argv: [String] = ["claude"], cwd: String? = "/Users/me/proj") -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, path: path, argv: argv, cwd: cwd)
}

private func hold(_ pid: Int32, child: Int32? = nil, adopted: Bool = false) -> HoldRecord {
    HoldRecord(pid: pid, childPid: child, command: "claude", kind: .claude,
               startedAt: Date(timeIntervalSince1970: 0), held: true, reason: .active, adopted: adopted)
}

@Suite struct ClaudeProcessMatchTests {
    @Test func nativeInstallByVersionedPath() {
        #expect(AutoDetect.isClaudeProcess(path: "/Users/me/.local/share/claude/versions/2.1.319", argv: ["claude"]))
    }

    @Test func byBinaryName() {
        #expect(AutoDetect.isClaudeProcess(path: "/opt/homebrew/bin/claude", argv: ["claude"]))
    }

    @Test func npmInstallRunsUnderNode() {
        #expect(AutoDetect.isClaudeProcess(
            path: "/opt/homebrew/bin/node",
            argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
    }

    @Test func otherProcessesDoNotMatch() {
        #expect(!AutoDetect.isClaudeProcess(path: "/opt/homebrew/bin/node", argv: ["node", "server.js"]))
        #expect(!AutoDetect.isClaudeProcess(
            path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            argv: ["Claude Helper"]))
        #expect(!AutoDetect.isClaudeProcess(path: "/Applications/Claude.app/Contents/MacOS/Claude", argv: ["Claude"]))
        #expect(!AutoDetect.isClaudeProcess(path: "/usr/local/bin/lidless", argv: ["lidless", "claude"]))
    }
}

@Suite struct TranscriptTests {
    @Test func projectFolderNameReplacesNonAlphanumerics() {
        #expect(AutoDetect.transcriptDirName(forCwd: "/Users/vitkon/Source/projects") == "-Users-vitkon-Source-projects")
        #expect(AutoDetect.transcriptDirName(forCwd: "/private/tmp/claude-501/a.b_c")
                == "-private-tmp-claude-501-a-b-c")
        #expect(AutoDetect.transcriptDirName(forCwd: "/Users/me/iCloud~md~obsidian") == "-Users-me-iCloud-md-obsidian")
    }

    @Test func latestTranscriptWriteIsNewestJSONL() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID())")
        let dir = projects.appendingPathComponent("-Users-me-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("a.jsonl"), new = dir.appendingPathComponent("b.jsonl")
        let other = dir.appendingPathComponent("notes.txt")
        for f in [old, new, other] { try Data("x".utf8).write(to: f) }
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: t2], ofItemAtPath: new.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 9_000)], ofItemAtPath: other.path)

        #expect(AutoDetect.latestTranscriptWrite(cwd: "/Users/me/proj", projectsDir: projects) == t2)
        #expect(AutoDetect.latestTranscriptWrite(cwd: "/Users/me/elsewhere", projectsDir: projects) == nil)
    }
}

@Suite struct AdoptionPlanTests {
    @Test func adoptsUnwrappedSessions() {
        let p = AutoDetect.plan(processes: [proc(100)], holds: [], enabled: true)
        #expect(p.adopt.map(\.pid) == [100])
        #expect(p.drop.isEmpty)
    }

    @Test func skipsSessionsAlreadyWrapped() {
        // lidless wrapper 50 spawned claude 100
        let byChild = AutoDetect.plan(processes: [proc(100, ppid: 50)], holds: [hold(50, child: 100)], enabled: true)
        #expect(byChild.adopt.isEmpty)
        let byParent = AutoDetect.plan(processes: [proc(100, ppid: 50)], holds: [hold(50)], enabled: true)
        #expect(byParent.adopt.isEmpty)
    }

    @Test func doesNotAdoptTwice() {
        let p = AutoDetect.plan(processes: [proc(100)], holds: [hold(100, adopted: true)], enabled: true)
        #expect(p.adopt.isEmpty)
    }

    @Test func ignoresNonClaudeProcesses() {
        let p = AutoDetect.plan(processes: [proc(100, path: "/bin/zsh", argv: ["zsh"])], holds: [], enabled: true)
        #expect(p.adopt.isEmpty)
    }

    @Test func disablingDropsAdoptedHoldsOnly() {
        let p = AutoDetect.plan(processes: [proc(100), proc(101)],
                                holds: [hold(100, adopted: true), hold(50, child: 101)], enabled: false)
        #expect(p.adopt.isEmpty)
        #expect(p.drop == [100])
    }
}

@Suite struct AdoptedHoldTests {
    @Test func recordsWithoutAdoptedFieldDecodeAsWrapped() throws {
        let v1 = #"{"command":"x","held":true,"kind":"plain","pid":7,"reason":"active","startedAt":0}"#
        let r = try HoldStore.decoder.decode(HoldRecord.self, from: Data(v1.utf8))
        #expect(!r.adopted)
        #expect(r.cwd == nil)
    }

    @Test func releaseAllKeepsAdoptedHoldsAsManuallyReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidless-test-\(UUID())")
        let paths = LidlessPaths(home: dir)
        try paths.ensure()
        let store = HoldStore(paths: paths)
        let power = FakePower()
        let probe = FakeProbe()
        probe.alive = [10, 100]
        let rec = Reconciler(store: store, power: power, probe: probe, lockURL: paths.lock)
        try rec.update(hold(10))
        try rec.update(hold(100, adopted: true))
        try rec.releaseAll()
        // Wrapped hold removed; adopted hold kept (so the watchdog doesn't re-adopt it) but released.
        #expect(store.list().map(\.pid) == [100])
        #expect(store.list().first?.held == false)
        #expect(store.list().first?.reason == .manual)
        #expect(!power.disabled)
    }
}
