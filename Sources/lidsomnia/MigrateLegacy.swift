import Darwin
import Foundation
import LidsomniaCore

/// Move a pre-rename (lidless) install over to the new names. Cheap when there's nothing to do,
/// never fails the command it runs before.
func migrateLegacyInstall() {
    let fm = FileManager.default
    let userHome = fm.homeDirectoryForCurrentUser
    let legacyHome = userHome.appendingPathComponent(Migration.legacyHomeName)
    let legacyAgent = userHome.appendingPathComponent("Library/LaunchAgents/\(Migration.legacyAgentLabel).plist")
    let legacyHomeExists = fm.fileExists(atPath: legacyHome.path)
    let legacyAgentExists = fm.fileExists(atPath: legacyAgent.path)
    guard legacyHomeExists || legacyAgentExists else { return }

    let paths = LidsomniaPaths.standard()
    let overridden = !(ProcessInfo.processInfo.environment["LIDSOMNIA_HOME"] ?? "").isEmpty
    let holdFiles = (try? fm.contentsOfDirectory(atPath: legacyHome.appendingPathComponent("holds").path)) ?? []
    let live = Migration.holdPids(in: holdFiles).contains { $0 != getpid() && ProcessScanner.isAlive($0) }

    let plan = Migration.plan(Migration.Facts(
        legacyHomeExists: legacyHomeExists, homeExists: fm.fileExists(atPath: paths.home.path),
        homeOverridden: overridden, legacyHoldsLive: live,
        legacyAgentExists: legacyAgentExists, agentExists: fm.fileExists(atPath: agentPlistURL.path)))

    if plan.moveHome {
        do {
            try fm.moveItem(at: legacyHome, to: paths.home)
            stderrLine("moved \(legacyHome.path) to \(paths.home.path) (lidless is now lidsomnia)")
        } catch {
            stderrLine("couldn't move \(legacyHome.path) to \(paths.home.path): \(error)")
        }
    }
    if plan.replaceAgent {
        do {
            if !fm.fileExists(atPath: agentPlistURL.path) { try installAgent(bin: selfExecutablePath()) }
            try? fm.removeItem(at: legacyAgent)
            stderrLine("watchdog is now \(agentLabel) (replaced \(Migration.legacyAgentLabel))")
            // Last: if launchd is running us as the old watchdog, this stops us.
            _ = try? shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Migration.legacyAgentLabel)"])
        } catch {
            stderrLine("couldn't replace the old watchdog: \(error); run `lidsomnia setup --agent-only`")
        }
    }
}

/// True when run through the old `lidless` name.
var invokedAsLegacyName: Bool {
    (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) == Migration.legacyName
}
