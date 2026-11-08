import Foundation

/// Adds lidless activity hooks to a `claude` invocation via `--settings`,
/// merging with any `--settings` the user already passed.
public enum ClaudeInjection {
    public static let busyEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse"]
    public static let idleEvents = ["Stop", "Notification"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    public static func isClaude(_ executable: String) -> Bool {
        (executable as NSString).lastPathComponent == "claude"
    }

    /// `args` excludes argv[0]. Returns new args with a single merged `--settings` first.
    public static func inject(args: [String], lidlessPath: String) throws -> [String] {
        var rest: [String] = []
        var settings: [String: Any] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--settings", i + 1 < args.count {
                merge(into: &settings, try load(args[i + 1]))
                i += 2
                continue
            }
            if a.hasPrefix("--settings=") {
                merge(into: &settings, try load(String(a.dropFirst("--settings=".count))))
                i += 1
                continue
            }
            rest.append(a)
            i += 1
        }
        merge(into: &settings, hooks(lidlessPath: lidlessPath))
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["--settings", String(decoding: data, as: UTF8.self)] + rest
    }

    static func hooks(lidlessPath: String) -> [String: Any] {
        let quoted = "'" + lidlessPath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        var events: [String: Any] = [:]
        for (list, state) in [(busyEvents, "busy"), (idleEvents, "idle")] {
            for event in list {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": "\(quoted) hook \(state)", "timeout": 5]],
                ]
                if toolEvents.contains(event) { group["matcher"] = "*" }
                events[event] = [group]
            }
        }
        return ["hooks": events]
    }

    /// `value` is a JSON string or a path to a JSON file (same as claude's `--settings`).
    static func load(_ value: String) throws -> [String: Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if trimmed.hasPrefix("{") {
            data = Data(trimmed.utf8)
        } else {
            let path = (trimmed as NSString).expandingTildeInPath
            guard let d = FileManager.default.contents(atPath: path) else {
                throw LidlessError.command("can't read --settings file \(path)")
            }
            data = d
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LidlessError.command("--settings value is not a JSON object")
        }
        return obj
    }

    /// Shallow merge, except `hooks.<event>` arrays are concatenated.
    static func merge(into base: inout [String: Any], _ other: [String: Any]) {
        for (key, value) in other {
            if key == "hooks", let newHooks = value as? [String: Any] {
                var hooks = base["hooks"] as? [String: Any] ?? [:]
                for (event, groups) in newHooks {
                    let existing = hooks[event] as? [Any] ?? []
                    hooks[event] = existing + (groups as? [Any] ?? [])
                }
                base["hooks"] = hooks
            } else {
                base[key] = value
            }
        }
    }
}
