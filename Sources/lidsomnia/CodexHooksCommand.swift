import Darwin
import Foundation
import LidsomniaCore

var codexHooksURL: URL {
    AutoDetect.defaultCodexSessionsDir().deletingLastPathComponent().appendingPathComponent("hooks.json")
}

/// Touched whenever a codex hook runs, so `doctor` can tell trusted hooks from unapproved ones.
func codexHooksSeenURL(_ paths: LidsomniaPaths) -> URL { paths.home.appendingPathComponent("codex-hooks-seen") }

func readCodexHooksFile() throws -> [String: Any] {
    guard let data = try? Data(contentsOf: codexHooksURL) else { return [:] }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LidsomniaError.command("\(codexHooksURL.path) isn't a JSON object")
    }
    return obj
}

func writeCodexHooksFile(_ root: [String: Any]) throws {
    try FileManager.default.createDirectory(at: codexHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: codexHooksURL, options: .atomic)
}

func installCodexHooksCommand() -> Int32 {
    do {
        let existing = try readCodexHooksFile()
        let backup = codexHooksURL.appendingPathExtension("bak")
        if !existing.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: codexHooksURL, to: backup)
        }
        let bin = selfExecutablePath()
        try writeCodexHooksFile(CodexHooks.installing(into: existing, bin: bin))
        print("""
        ✓ added lidsomnia's busy/idle hooks to \(codexHooksURL.path)

        Codex runs new hooks only after you approve them, once:
          1. start codex
          2. type /hooks and trust the six lidsomnia hooks
        Then `lidsomnia doctor` shows them as working after your next prompt.
        """)
        return 0
    } catch {
        stderrLine("\(error)")
        return 1
    }
}

func removeCodexHooks() -> Bool {
    guard FileManager.default.fileExists(atPath: codexHooksURL.path),
          let root = try? readCodexHooksFile(), CodexHooks.installedBinary(in: root) != nil else { return false }
    try? writeCodexHooksFile(CodexHooks.removing(from: root))
    return true
}

/// `lidsomnia hook codex busy|idle`, run by Codex. Prints nothing (hook stdout can be parsed
/// by Codex), never fails.
func codexHookCommand(_ state: ActivityState) -> Int32 {
    let paths = LidsomniaPaths.standard()
    let store = HoldStore(paths: paths)
    try? Data().write(to: codexHooksSeenURL(paths))

    var ancestors: [Int32] = []
    var pid = getppid()
    while pid > 1, ancestors.count < 32 {
        ancestors.append(pid)
        guard let parent = ProcessScanner.ppid(pid), parent != pid else { break }
        pid = parent
    }
    guard let hold = CodexHooks.hold(forAncestors: ancestors, holds: store.list()) else { return 0 }
    try? store.writeActivity(Activity(state: state, at: Date()), to: store.activityURL(pid: hold.pid))
    if !hold.adopted, shouldWakeWrapper(record: hold, state: state),
       SystemProcessProbe().isLiveLidsomnia(pid: hold.pid) {
        kill(hold.pid, SIGUSR1)
    }
    return 0
}
