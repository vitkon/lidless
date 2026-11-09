import Foundation

/// How long until the battery floor releases every hold, and when to warn the phone about it.
public enum Battery {
    /// Minutes until the battery reaches `floor`, scaled from macOS's time-to-empty estimate
    /// (which assumes the current load continues). nil on AC, at/below the floor, or without an estimate.
    public static func minutesToFloor(_ r: Readings, floor: Int) -> Int? {
        guard r.onBattery, let pct = r.batteryPercent, pct > floor, let empty = r.minutesToEmpty, empty > 0
        else { return nil }
        return Int((Double(empty) * Double(pct - floor) / Double(pct)).rounded())
    }

    /// Should the watchdog send the `batterySoon` warning now? Once per discharge: the caller
    /// re-arms it when the Mac is on AC or nothing is held.
    public static func warningDue(_ r: Readings, config: Config, holding: Bool, alreadyWarned: Bool) -> Bool {
        let lead = config.alerts.batteryWarningMinutes
        guard lead > 0, holding, !alreadyWarned, let left = minutesToFloor(r, floor: config.batteryFloorPercent)
        else { return false }
        return Double(left) <= lead
    }

    /// The warning re-arms after the Mac charges or every hold ends.
    public static func shouldRearm(_ r: Readings, holding: Bool) -> Bool { !r.onBattery || !holding }

    public static func format(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60)m"
    }
}
