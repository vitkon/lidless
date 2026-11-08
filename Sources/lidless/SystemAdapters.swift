import Darwin
import Foundation
import IOKit.ps
import LidlessCore

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

    private func sudoPmset(_ args: [String]) throws {
        let r = try shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args)
        guard r.status == 0 else {
            throw LidlessError.privilege(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct SystemReadings: PowerReadingsSource {
    func read() -> Readings {
        var onBattery = false
        var percent: Int?
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
            }
        }
        return Readings(onBattery: onBattery, batteryPercent: percent, thermal: Self.thermal())
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
    func isLiveLidless(pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return (String(cString: buf) as NSString).lastPathComponent == "lidless"
    }
}

struct OsascriptNotifier: Notifier {
    func notify(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? shell("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"lidless\""])
    }
}

/// Absolute, symlink-resolved path of the running lidless binary.
func selfExecutablePath() -> String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }
    return CommandLine.arguments[0]
}

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data("lidless: \(s)\n".utf8))
}
