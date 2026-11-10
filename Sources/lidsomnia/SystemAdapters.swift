import Darwin
import Foundation
import IOKit
import IOKit.ps
import LidsomniaCore

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Run a program with captured output (stdin is inherited, so `sudo` can prompt when not using -n).
@discardableResult
func shell(_ path: String, _ args: [String], captureOutput: Bool = true) throws -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    if captureOutput {
        p.standardOutput = out
        p.standardError = err
    }
    try p.run()
    var outData = Data(), errData = Data()
    if captureOutput {
        outData = out.fileHandleForReading.readDataToEndOfFile()
        errData = err.fileHandleForReading.readDataToEndOfFile()
    }
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus,
                       stdout: String(decoding: outData, as: UTF8.self),
                       stderr: String(decoding: errData, as: UTF8.self))
}

struct PmsetPowerControl: PowerControl {
    func sleepDisabled() throws -> Bool {
        let r = try shell("/usr/bin/pmset", ["-g"])
        for line in r.stdout.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        return false
    }

    func setSleepDisabled(_ on: Bool) throws {
        try sudoPmset(["-a", "disablesleep", on ? "1" : "0"])
    }

    func sleepNow() throws {
        try sudoPmset(["sleepnow"])
    }

    /// Low Power Mode for battery power, or nil if this Mac doesn't have it.
    func lowPowerOnBattery() -> Bool? {
        guard let out = try? shell("/usr/bin/pmset", ["-g", "custom"]).stdout else { return nil }
        var inBattery = false
        for line in out.split(separator: "\n") {
            if !line.hasPrefix(" ") { inBattery = line.hasPrefix("Battery Power"); continue }
            let w = line.split(whereSeparator: \.isWhitespace)
            if inBattery, w.first == "lowpowermode" { return w.last == "1" }
        }
        return nil
    }

    func setLowPowerOnBattery(_ on: Bool) throws {
        try sudoPmset(["-b", "lowpowermode", on ? "1" : "0"])
    }

    /// The sudoers rule covers Low Power Mode (rules from before 2.4.0 don't).
    func lowPowerAllowed() -> Bool { passwordless("/usr/bin/pmset -b lowpowermode 1") }

    /// The sudoers rule lets this run without a password.
    func passwordless(_ command: String) -> Bool {
        guard let r = try? shell("/usr/bin/sudo", ["-n", "-l"]), r.status == 0 else { return false }
        return Sudoers.passwordless(command, in: r.stdout)
    }

    private func sudoPmset(_ args: [String]) throws {
        let r = try shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args)
        guard r.status == 0 else {
            throw LidsomniaError.privilege(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct SystemReadings: PowerReadingsSource {
    func read() -> Readings {
        var onBattery = false
        var percent: Int?
        var toEmpty: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                onBattery = type == "Battery Power"
            }
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      desc["Type"] as? String == "InternalBattery",
                      let cur = desc["Current Capacity"] as? Int,
                      let max = desc["Max Capacity"] as? Int, max > 0
                else { continue }
                percent = cur * 100 / max
                if let t = desc["Time to Empty"] as? Int, t > 0 { toEmpty = t }  // -1 while calculating
            }
        }
        let temp = (Self.registry("AppleSmartBattery", "Temperature") as? Int).map { Double($0) / 100 }
        return Readings(onBattery: onBattery, batteryPercent: percent, thermal: Self.thermal(),
                        minutesToEmpty: onBattery ? toEmpty : nil,
                        batteryTempC: temp.flatMap { $0 > 0 ? $0 : nil },
                        lidClosed: Self.registry("IOPMrootDomain", "AppleClamshellState") as? Bool)
    }

    /// A property of the first IOKit service of that class, or nil (no battery, no lid, …).
    static func registry(_ serviceClass: String, _ key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}

struct SystemProcessProbe: ProcessProbe {
    func isLive(_ hold: HoldRecord) -> Bool {
        guard hold.adopted else { return isLiveLidsomnia(pid: hold.pid) }
        guard ProcessScanner.isAlive(hold.pid), let path = ProcessScanner.path(hold.pid) else { return false }
        return AutoDetect.agentKind(path: path, argv: ProcessScanner.argv(hold.pid)) == hold.kind
    }

    func isLiveLidsomnia(pid: Int32) -> Bool {
        guard ProcessScanner.isAlive(pid), let path = ProcessScanner.path(pid) else { return false }
        // proc_pidpath resolves symlinks; a wrapper started before the rename runs a `lidless` binary.
        let name = (path as NSString).lastPathComponent
        return name == "lidsomnia" || name == Migration.legacyName
    }
}

struct OsascriptNotifier: Notifier {
    func notify(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? shell("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"lidsomnia\""])
    }
}

/// Absolute path of the running lidsomnia binary, as invoked. Symlinks are deliberately NOT
/// resolved: with Homebrew, /opt/homebrew/bin/lidsomnia is stable while the Cellar path it
/// points to changes on every upgrade, which would break the watchdog and hooks.
func selfExecutablePath() -> String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
    let invoked = URL(fileURLWithPath: String(cString: buf)).standardizedFileURL.path
    return Migration.preferredBinary(invoked: invoked) { FileManager.default.isExecutableFile(atPath: $0) }
}

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data("lidsomnia: \(s)\n".utf8))
}
