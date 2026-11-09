import Foundation

/// `lidsomnia setup --codex-hooks`: busy/idle hooks in `~/.codex/hooks.json`, approved once in
/// Codex (`/hooks`). They're global, so a hook finds its hold by walking up its parent processes
/// to the Codex process lidsomnia holds (wrapped: the hold's child; adopted: the hold itself).
public enum CodexHooks {
    public static let busyEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse"]
    public static let idleEvents = ["Stop", "Interrupt", "SessionEnd"]
    /// SessionEnd and Interrupt allow at most 3 s; the hook takes milliseconds.
    static let timeout = 3

    public static func command(bin: String, state: ActivityState) -> String {
        let quoted = bin.contains(" ") ? "'\(bin.replacingOccurrences(of: "'", with: #"'\''"#))'" : bin
        return "\(quoted) hook codex \(state.rawValue)"
    }

    static func isOurs(_ handler: Any) -> Bool {
        guard let cmd = (handler as? [String: Any])?["command"] as? String else { return false }
        return cmd.contains("lidsomnia") && cmd.contains(" hook codex ")
    }

    /// `hooks.json` contents with lidsomnia's hooks removed (other hooks untouched).
    public static func removing(from root: [String: Any]) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var g = group
                let handlers = (g["hooks"] as? [Any] ?? []).filter { !isOurs($0) }
                if handlers.isEmpty { return nil }
                g["hooks"] = handlers
                return g
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks
        return root
    }

    /// `hooks.json` contents with lidsomnia's hooks (re)installed for `bin`.
    public static func installing(into root: [String: Any], bin: String) -> [String: Any] {
        var root = removing(from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (events, state) in [(busyEvents, ActivityState.busy), (idleEvents, .idle)] {
            for event in events {
                let group: [String: Any] = ["hooks": [[
                    "type": "command", "command": command(bin: bin, state: state), "timeout": timeout,
                ]]]
                hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
            }
        }
        root["hooks"] = hooks
        return root
    }

    /// The lidsomnia binary the installed hooks run, or nil if they aren't installed.
    public static func installedBinary(in root: [String: Any]) -> String? {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        for group in hooks["Stop"] as? [[String: Any]] ?? [] {
            for h in group["hooks"] as? [Any] ?? [] where isOurs(h) {
                let cmd = (h as? [String: Any])?["command"] as? String ?? ""
                return cmd.components(separatedBy: " hook codex ").first?.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
        }
        return nil
    }

    /// The codex hold a hook process belongs to, given its ancestors (nearest first).
    public static func hold(forAncestors ancestors: [Int32], holds: [HoldRecord]) -> HoldRecord? {
        let codex = holds.filter { $0.kind == .codex }
        for pid in ancestors {
            if let h = codex.first(where: { $0.childPid == pid || ($0.adopted && $0.pid == pid) }) { return h }
        }
        return nil
    }
}

extension CodexHooks {
    /// A codex session's activity: hooks when they've reported, else session-file writes.
    /// Never earlier than the hold's start, so a new hold gets a full idle window.
    public static func activity(hook: Activity?, lastWrite: Date?, startedAt: Date) -> Activity {
        if let h = hook, h.state == .busy { return h }
        let at = [hook?.at, lastWrite, startedAt].compactMap { $0 }.max()!
        return Activity(state: .idle, at: at)
    }
}
