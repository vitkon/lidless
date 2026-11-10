import Foundation

/// Bag mode: a heat limit on the battery's temperature, which climbs steadily in a closed bag
/// and is what heat damages. macOS's thermal state only escalates once the chip is throttling hard.
public enum Heat {
    /// The `hotSoon` warning goes out this many °C below the limit.
    public static let warnBelow: Double = 3
    /// After a heat release, the hold comes back only once the battery is this far below the limit.
    public static let coolBy: Double = 5

    public static func isHot(_ r: Readings, config: Config, wasHot: Bool) -> Bool {
        guard let t = r.batteryTempC else { return false }
        let limit = config.batteryTempLimitC
        return t >= limit || (wasHot && t > limit - coolBy)
    }

    /// Once per warm spell: the caller re-arms it with `shouldRearm`.
    public static func warningDue(_ r: Readings, config: Config, holding: Bool, alreadyWarned: Bool) -> Bool {
        guard holding, !alreadyWarned, let t = r.batteryTempC else { return false }
        let limit = config.batteryTempLimitC
        return t >= limit - warnBelow && t < limit
    }

    public static func shouldRearm(_ r: Readings, config: Config, holding: Bool) -> Bool {
        !holding || (r.batteryTempC ?? 0) <= config.batteryTempLimitC - coolBy
    }

    public static func format(_ c: Double) -> String { "\(Int(c.rounded()))°C" }
}

/// Low Power Mode (battery only) while the lid is closed: agents mostly wait on the network, so a
/// slower chip costs little, and it draws less and runs cooler. lidsomnia only ever turns off what it
/// turned on, and stops if you switch it off yourself.
public enum LowPower {
    /// What lidsomnia has done, kept in `~/.lidsomnia/low-power`.
    public enum Marker: String, Sendable {
        /// lidsomnia turned it on.
        case on
        /// lidsomnia turned it on, then you turned it off: leave it alone until it's no longer wanted.
        case overridden
    }

    public enum Action: Equatable, Sendable { case turnOn, turnOff, none }

    public static func wanted(config: Config, readings: Readings, holding: Bool) -> Bool {
        config.lowPowerWhenClosed && holding && readings.lidClosed == true
    }

    /// The action to take and the marker to keep afterwards.
    public static func plan(wanted: Bool, isOn: Bool, marker: Marker?) -> (action: Action, marker: Marker?) {
        switch (wanted, marker) {
        case (true, nil): return isOn ? (.none, nil) : (.turnOn, .on)  // already on: yours, not touched
        case (true, .on): return isOn ? (.none, .on) : (.none, .overridden)
        case (true, .overridden): return (.none, .overridden)
        case (false, .on): return (isOn ? .turnOff : .none, nil)
        case (false, _): return (.none, nil)
        }
    }
}

extension Readings {
    /// "battery, 64%, about 3h40m to the 10% floor, 31°C, lid closed, thermal nominal"
    public static func summary(_ r: Readings, config: Config) -> String {
        var parts = [r.onBattery ? "battery" : "AC", r.batteryPercent.map { "\($0)%" } ?? "n/a"]
        if let m = Battery.minutesToFloor(r, floor: config.batteryFloorPercent) {
            parts.append("about \(Battery.format(m)) to the \(config.batteryFloorPercent)% floor")
        }
        if let t = r.batteryTempC { parts.append(Heat.format(t)) }
        if r.lidClosed == true { parts.append("lid closed") }
        parts.append("thermal \(r.thermal.rawValue)")
        return parts.joined(separator: ", ")
    }
}
