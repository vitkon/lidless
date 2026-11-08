import Foundation

public struct DecisionInput: Sendable {
    public var kind: HoldKind
    public var startedAt: Date
    public var activity: Activity?
    public var readings: Readings
    public var config: Config
    public var now: Date
    public var manuallyReleased: Bool

    public init(kind: HoldKind, startedAt: Date, activity: Activity?, readings: Readings,
                config: Config, now: Date, manuallyReleased: Bool) {
        self.kind = kind
        self.startedAt = startedAt
        self.activity = activity
        self.readings = readings
        self.config = config
        self.now = now
        self.manuallyReleased = manuallyReleased
    }
}

public struct Decision: Equatable, Sendable {
    public var held: Bool
    public var reason: HoldReason

    public init(held: Bool, reason: HoldReason) {
        self.held = held
        self.reason = reason
    }
}

/// Should this hold keep the Mac awake right now? Rules apply in order; the first match wins.
public func decide(_ i: DecisionInput) -> Decision {
    if i.manuallyReleased {
        return Decision(held: false, reason: .manual)
    }
    if i.readings.onBattery, let pct = i.readings.batteryPercent, pct <= i.config.batteryFloorPercent {
        return Decision(held: false, reason: .lowBattery)
    }
    if i.readings.thermal >= i.config.thermalLimit {
        return Decision(held: false, reason: .thermal)
    }
    if i.kind == .claude {
        let state = i.activity?.state ?? .idle
        let since = i.activity?.at ?? i.startedAt
        if state == .idle, i.now.timeIntervalSince(since) >= i.config.idleTimeoutMinutes * 60 {
            return Decision(held: false, reason: .idle)
        }
    }
    return Decision(held: true, reason: .active)
}
