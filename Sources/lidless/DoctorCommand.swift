import Darwin
import Foundation
import LidlessCore

/// `lidless doctor`: check the setup and print the fix for anything wrong.
func doctorCommand() -> Int32 {
    let paths = LidlessPaths.standard()
    let fm = FileManager.default
    let probe = SystemProcessProbe()

    let sudoAllowed = (try? shell("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]))?.status == 0

    // Watchdog
    let plist = (try? Data(contentsOf: agentPlistURL))
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    let agentProgram = (plist?["ProgramArguments"] as? [String])?.first
    let launchd = try? shell("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"])
    let agentLoaded = launchd?.status == 0
    var lastExit: Int?
    if let out = launchd?.stdout, let line = out.split(separator: "\n").first(where: { $0.contains("last exit code") }) {
        lastExit = Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    // Binaries on PATH, in PATH order
    let pathBinaries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("lidless").standardizedFileURL.path }
        .filter { fm.isExecutableFile(atPath: $0) }

    // Holds
    let store = HoldStore(paths: paths)
    let holds = store.list()
    let live = holds.filter { probe.isLive($0) }

    // Config
    let configData = try? Data(contentsOf: paths.config)
    var configError: String?
    var config = Config()
    if let data = configData {
        do { config = try Config.decode(data) } catch { configError = describe(error) }
    }
    var alertsError: String?
    if config.alerts.isConfigured {
        let probeEvent = AlertEvent(kind: .test, host: "doctor", command: "", pid: 0, exitCode: nil, durationSeconds: 0,
                                    batteryPercent: nil, onBattery: false, thermal: .nominal, at: Date())
        do { _ = try Alerts.requests(for: probeEvent, config: config) } catch { alertsError = "\(error)" }
    }

    let claude = try? shell("/usr/bin/env", ["claude", "--version"])
    let claudeVersion = claude?.status == 0
        ? claude?.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        : nil

    let codex = try? shell("/usr/bin/env", ["codex", "--version"])
    let codexVersion = codex?.status == 0
        ? codex?.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        : nil

    var facts = DoctorFacts(
        sudoAllowed: sudoAllowed,
        agentPlistExists: plist != nil, agentProgram: agentProgram,
        agentProgramExists: agentProgram.map { fm.isExecutableFile(atPath: $0) } ?? false,
        agentLoaded: agentLoaded, agentLastExit: lastExit,
        runningBinary: selfExecutablePath(), pathBinaries: pathBinaries,
        sleepDisabled: try? PmsetPowerControl().sleepDisabled(),
        liveHeldHolds: live.filter(\.held).count, deadHolds: holds.count - live.count,
        configExists: configData != nil, configError: configError,
        unknownConfigKeys: configData.map(Doctor.unknownKeys(in:)) ?? [], alertsError: alertsError,
        claudeVersion: claudeVersion, readings: SystemReadings().read(), config: config)
    facts.codexVersion = codexVersion

    let checks = Doctor.evaluate(facts)
    print("lidless \(lidlessVersion) doctor\n")
    let width = (checks.map(\.name.count).max() ?? 0) + 2
    for c in checks {
        print("\(c.status.symbol) \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))\(c.detail)")
        if let fix = c.fix {
            let label = c.status == .ok ? "try" : "fix"
            print("  \(String(repeating: " ", count: width))\(label): \(fix)")
        }
    }
    let problems = checks.filter { $0.status != .ok }.count
    print(problems == 0 ? "\nAll good." : "\n\(problems) thing\(problems == 1 ? "" : "s") to look at.")
    return Doctor.exitCode(checks)
}

private func describe(_ error: Error) -> String {
    if case DecodingError.dataCorrupted(let ctx) = error {
        return (ctx.underlyingError as NSError?)?.localizedDescription ?? ctx.debugDescription
    }
    if case DecodingError.typeMismatch(_, let ctx) = error {
        return "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
    }
    if case DecodingError.dataCorrupted = error { return "not valid JSON" }
    return "\(error)"
}
