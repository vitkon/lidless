import Foundation

public struct DecisionInput: Sendable {
    public var kind: HoldKind
    public var startedAt: Date
    public var activity: Activity?
    public var readings: Readings
    public var config: Config
    public var now: Date
    public var manuallyReleased: Bool
    /// A phone "Keep awake" tap: no idle release before this.
    public var extendedUntil: Date?

    public init(kind: HoldKind, startedAt: Date, activity: Activity?, readings: Readings,
                config: Config, now: Date, manuallyReleased: Bool, extendedUntil: Date? = nil) {
        self.extendedUntil = extendedUntil
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

/// Should a hook nudge its wrapper (SIGUSR1) to re-evaluate right away instead of waiting
/// for the next 30 s tick? Only when activity resumes on a hold that isn't currently held,
/// and not after a manual release (which is permanent for the run).
public func shouldWakeWrapper(record: HoldRecord?, state: ActivityState) -> Bool {
    guard state == .busy, let r = record else { return false }
    return !r.held && r.reason != .manual
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
    if let at = idleReleaseAt(i), i.now >= at {
        return Decision(held: false, reason: .idle)
    }
    return Decision(held: true, reason: .active)
}

/// When an idle agent session's hold gets released, if nothing happens before then.
/// nil for plain commands and busy sessions.
public func idleReleaseAt(_ i: DecisionInput) -> Date? {
    guard i.kind != .plain, (i.activity?.state ?? .idle) == .idle else { return nil }
    let since = i.activity?.at ?? i.startedAt
    let at = since.addingTimeInterval(i.config.idleTimeoutMinutes * 60)
    return max(at, i.extendedUntil ?? .distantPast)
}
