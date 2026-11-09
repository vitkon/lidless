import Foundation
import Testing
@testable import LidsomniaCore

private let bin = "/Users/me/.local/bin/lidsomnia"

private func settingsArg(_ args: [String]) throws -> [String: Any] {
    let idx = try #require(args.firstIndex(of: "--settings"))
    let json = args[idx + 1]
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func commands(_ settings: [String: Any], _ event: String) -> [String] {
    let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Suite struct ClaudeInjectionTests {
    @Test func detectsClaudeByBasename() {
        #expect(ClaudeInjection.isClaude("claude"))
        #expect(ClaudeInjection.isClaude("/Users/me/.local/bin/claude"))
        #expect(!ClaudeInjection.isClaude("claude-foo"))
        #expect(!ClaudeInjection.isClaude("npm"))
    }

    @Test func addsHooksForEveryEventAtFront() throws {
        let out = try ClaudeInjection.inject(args: ["--remote-control", "myjob"], lidsomniaPath: bin)
        #expect(out.first == "--settings")
        #expect(Array(out.suffix(2)) == ["--remote-control", "myjob"])
        let s = try settingsArg(out)
        #expect(commands(s, "UserPromptSubmit") == ["'\(bin)' hook busy"])
        #expect(commands(s, "PreToolUse") == ["'\(bin)' hook busy"])
        #expect(commands(s, "PostToolUse") == ["'\(bin)' hook busy"])
        #expect(commands(s, "Stop") == ["'\(bin)' hook idle"])
        #expect(commands(s, "Notification") == ["'\(bin)' hook idle"])
    }

    @Test func mergesExistingJSONSettings() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let out = try ClaudeInjection.inject(args: ["--settings", existing, "-p", "hi"], lidsomniaPath: bin)
        #expect(out.filter { $0 == "--settings" }.count == 1)
        #expect(Array(out.suffix(2)) == ["-p", "hi"])
        let s = try settingsArg(out)
        #expect(s["model"] as? String == "opus")
        #expect(commands(s, "Stop") == ["say done", "'\(bin)' hook idle"])
    }

    @Test func mergesEqualsFormAndFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID()).json")
        try Data(#"{"env":{"A":"1"}}"#.utf8).write(to: file)
        let out = try ClaudeInjection.inject(args: ["--settings=\(file.path)"], lidsomniaPath: bin)
        let s = try settingsArg(out)
        #expect((s["env"] as? [String: String])?["A"] == "1")
        #expect(!commands(s, "Stop").isEmpty)
    }

    @Test func quotesPathWithSpaces() throws {
        let out = try ClaudeInjection.inject(args: [], lidsomniaPath: "/tmp/my dir/lidsomnia")
        #expect(commands(try settingsArg(out), "Stop") == ["'/tmp/my dir/lidsomnia' hook idle"])
    }

    @Test func unreadableSettingsThrows() {
        #expect(throws: LidsomniaError.self) {
            try ClaudeInjection.inject(args: ["--settings", "/nonexistent/x.json"], lidsomniaPath: bin)
        }
    }
}
