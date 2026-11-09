import Foundation

/// A running process, as seen by the auto-detect scanner.
public struct ProcInfo: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var path: String
    public var argv: [String]
    public var cwd: String?

    public init(pid: Int32, ppid: Int32, path: String, argv: [String], cwd: String?) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.argv = argv
        self.cwd = cwd
    }
}

public struct AdoptionPlan: Equatable, Sendable {
    public var adopt: [ProcInfo]
    public var drop: [Int32]
}

/// Picks up agent sessions (Claude Code, Codex) that weren't started through `lidsomnia`
/// (opt-in via `autoDetect`).
public enum AutoDetect {
    /// Which agent a process is, if any.
    public static func agentKind(path: String, argv: [String]) -> HoldKind? {
        if isClaudeProcess(path: path, argv: argv) { return .claude }
        if isCodexProcess(path: path, argv: argv) { return .codex }
        return nil
    }

    /// Kind for `lidsomnia <cmd>`, from the command name.
    public static func wrapperKind(_ executable: String) -> HoldKind {
        switch (executable as NSString).lastPathComponent {
        case "claude": return .claude
        case "codex": return .codex
        default: return .plain
        }
    }

    /// Homebrew/standalone/VS Code builds are a binary named `codex`; npm runs it under node.
    /// The binary also re-executes itself under other names for helpers (e.g. `apply_patch`), so
    /// when argv is readable, the launched name (`argv[0]`) decides.
    public static func isCodexProcess(path: String, argv: [String]) -> Bool {
        let base = (path as NSString).lastPathComponent
        if base.hasPrefix("node") { return argv.contains(where: { $0.contains("@openai/codex/") }) }
        guard let arg0 = argv.first else { return base == "codex" }
        return (arg0 as NSString).lastPathComponent == "codex"
    }

    public static func defaultCodexSessionsDir() -> URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    /// Newest write to a Codex session file since `since`. Prefers sessions whose recorded `cwd`
    /// matches; if none do (e.g. `codex -C dir`, or a server process running from `/`), falls back to
    /// the newest write of any session, which errs toward keeping the Mac awake.
    public static func latestCodexWrite(cwd: String?, since: Date,
                                        sessionsDir: URL = defaultCodexSessionsDir()) -> Date? {
        guard let walker = FileManager.default.enumerator(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var recent: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m >= since else { continue }
            recent.append((url, m))
        }
        guard !recent.isEmpty else { return nil }
        if let cwd {
            let want = normalize(cwd)
            let matching = recent.filter { sessionCwd($0.url).map(normalize) == want }
            if let newest = matching.map(\.modified).max() { return newest }
        }
        return recent.map(\.modified).max()
    }

    /// `payload.cwd` from the first (`session_meta`) line of a rollout file.
    static func sessionCwd(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 64 * 1024)
        guard let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Native installs run `~/.local/share/claude/versions/<version>` (the kernel name is the
    /// version, not "claude"); npm installs run under node. The native binary also runs bundled
    /// tools by re-executing itself as e.g. `ugrep`, so when argv is readable, `argv[0]` decides.
    public static func isClaudeProcess(path: String, argv: [String]) -> Bool {
        let base = (path as NSString).lastPathComponent
        if base == "lidsomnia" { return false }
        if base.hasPrefix("node") { return argv.contains(where: { $0.contains("@anthropic-ai/claude-code/") }) }
        guard let arg0 = argv.first else { return base == "claude" || path.contains("/claude/versions/") }
        return (arg0 as NSString).lastPathComponent == "claude"
    }

    /// Claude Code keeps transcripts in `~/.claude/projects/<cwd with non-alphanumerics as "-">/`.
    public static func transcriptDirName(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static func defaultProjectsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Newest `*.jsonl` modification time in the session's project folder: the activity signal
    /// for sessions that can't have hooks injected.
    public static func latestTranscriptWrite(cwd: String, projectsDir: URL = defaultProjectsDir()) -> Date? {
        let dir = projectsDir.appendingPathComponent(transcriptDirName(forCwd: cwd))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// Which processes to adopt and which adopted holds to drop.
    public static func plan(processes: [ProcInfo], holds: [HoldRecord], enabled: Bool) -> AdoptionPlan {
        let adoptedPids = Set(holds.filter(\.adopted).map(\.pid))
        guard enabled else { return AdoptionPlan(adopt: [], drop: adoptedPids.sorted()) }

        let wrappers = holds.filter { !$0.adopted }
        let wrapperPids = Set(wrappers.map(\.pid))
        let wrappedChildren = Set(wrappers.compactMap(\.childPid))
        let agentPids = Set(processes.filter { agentKind(path: $0.path, argv: $0.argv) != nil }.map(\.pid))
        let adopt = processes.filter {
            agentKind(path: $0.path, argv: $0.argv) != nil
                && !adoptedPids.contains($0.pid)
                && !wrappedChildren.contains($0.pid)
                && !wrapperPids.contains($0.ppid)
                && !agentPids.contains($0.ppid)  // helper processes of an agent we already track
        }
        return AdoptionPlan(adopt: adopt.sorted { $0.pid < $1.pid }, drop: [])
    }
}
