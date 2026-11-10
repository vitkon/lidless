import Foundation
import LidsomniaCore

/// Watchdog steps that are about the whole Mac, not one hold: the battery and heat warnings
/// (one alert however many jobs are held) and Low Power Mode while the lid is closed.
func machineGuards(store: HoldStore, probe: ProcessProbe, config: Config, paths: LidsomniaPaths, stamp: String) {
    let r = SystemReadings().read()
    let held = store.list().filter { $0.held && probe.isLive($0) }

    func warnOnce(_ kind: AlertKind, marker name: String, rearm: Bool, due: (Bool) -> Bool, until: Date? = nil,
                  log: String) {
        let marker = paths.home.appendingPathComponent(name)
        if rearm {
            try? FileManager.default.removeItem(at: marker)
            return
        }
        guard due(FileManager.default.fileExists(atPath: marker.path)), var job = held.first else { return }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        print("\(stamp) \(log), warned")
        if held.count > 1 { job.command = "\(held.count) jobs" }
        sendAlert(kind, record: job, readings: r, exitCode: nil, config: config, until: until)
    }

    let left = Battery.minutesToFloor(r, floor: config.batteryFloorPercent)
    warnOnce(.batterySoon, marker: "battery-warned", rearm: Battery.shouldRearm(r, holding: !held.isEmpty),
             due: { Battery.warningDue(r, config: config, holding: true, alreadyWarned: $0) },
             until: left.map { Date().addingTimeInterval(Double($0) * 60) },
             log: "battery: about \(left ?? 0)m to the \(config.batteryFloorPercent)% floor")
    warnOnce(.hotSoon, marker: "heat-warned", rearm: Heat.shouldRearm(r, config: config, holding: !held.isEmpty),
             due: { Heat.warningDue(r, config: config, holding: true, alreadyWarned: $0) },
             log: "heat: battery at \(r.batteryTempC.map(Heat.format) ?? "?")")

    applyLowPower(wanted: LowPower.wanted(config: config, readings: r, holding: !held.isEmpty), paths: paths, stamp: stamp)
}

func lowPowerMarkerURL(_ paths: LidsomniaPaths) -> URL { paths.home.appendingPathComponent("low-power") }

/// Turn Low Power Mode on or off to match `wanted`, touching only what lidsomnia turned on.
/// Quietly does nothing without the sudoers rule; `doctor` reports that.
func applyLowPower(wanted: Bool, paths: LidsomniaPaths, stamp: String) {
    let power = PmsetPowerControl()
    let url = lowPowerMarkerURL(paths)
    let marker = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
        LowPower.Marker(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard marker != nil || wanted, let isOn = power.lowPowerOnBattery() else { return }
    let (action, next) = LowPower.plan(wanted: wanted, isOn: isOn, marker: marker)
    if action != .none {
        guard power.lowPowerAllowed() else { return }
        do {
            try power.setLowPowerOnBattery(action == .turnOn)
            print("\(stamp) low power mode \(action == .turnOn ? "on (lid closed)" : "off")")
        } catch {
            stderrLine("couldn't change low power mode: \(error)")
            return
        }
    }
    if let next {
        try? Data(next.rawValue.utf8).write(to: url, options: .atomic)
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}
