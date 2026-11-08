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

/// Picks up `claude` sessions that weren't started through `lidless` (opt-in via `autoDetect`).
public enum AutoDetect {
    /// Native installs run `~/.local/share/claude/versions/<version>` (the kernel name is the
    /// version, not "claude"); npm installs run under node.
    public static func isClaudeProcess(path: String, argv: [String]) -> Bool {
        let base = (path as NSString).lastPathComponent
        if base == "claude" || path.contains("/claude/versions/") { return true }
        if let arg0 = argv.first, (arg0 as NSString).lastPathComponent == "claude", base != "lidless" { return true }
        if base.hasPrefix("node"), argv.contains(where: { $0.contains("@anthropic-ai/claude-code/") }) { return true }
        return false
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
        let adopt = processes.filter {
            isClaudeProcess(path: $0.path, argv: $0.argv)
                && !adoptedPids.contains($0.pid)
                && !wrappedChildren.contains($0.pid)
                && !wrapperPids.contains($0.ppid)
        }
        return AdoptionPlan(adopt: adopt.sorted { $0.pid < $1.pid }, drop: [])
    }
}
