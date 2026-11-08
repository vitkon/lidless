import Foundation

public struct ReconcileResult: Equatable, Sendable {
    public var removed: [Int32]
    public var desired: Bool
    public var changed: Bool
}

/// Keeps `SleepDisabled` equal to "some live hold has held == true".
/// Every mutation runs under an exclusive flock so concurrent wrappers can't race.
public struct Reconciler {
    public let store: HoldStore
    public let power: PowerControl
    public let probe: ProcessProbe
    public let lockURL: URL

    public init(store: HoldStore, power: PowerControl, probe: ProcessProbe, lockURL: URL) {
        self.store = store
        self.power = power
        self.probe = probe
        self.lockURL = lockURL
    }

    /// Write (or overwrite) a hold, then reconcile. The record is written even if pmset fails.
    @discardableResult
    public func update(_ record: HoldRecord) throws -> ReconcileResult {
        try withLock {
            try store.write(record)
            return try reconcileLocked()
        }
    }

    @discardableResult
    public func remove(pid: Int32) throws -> ReconcileResult {
        try withLock {
            store.remove(pid: pid)
            return try reconcileLocked()
        }
    }

    /// Drop dead holds and fix the flag. This is what the watchdog runs.
    @discardableResult
    public func reconcile() throws -> ReconcileResult {
        try withLock { try reconcileLocked() }
    }

    /// Panic button: drop every hold and turn sleep back on. Adopted holds are kept as
    /// manually released (not deleted) so the watchdog doesn't immediately re-adopt them.
    public func releaseAll() throws {
        try withLock {
            for var r in store.list() {
                if r.adopted {
                    r.held = false
                    r.reason = .manual
                    try store.write(r)
                } else {
                    store.remove(pid: r.pid)
                }
            }
            _ = try reconcileLocked()
        }
    }

    private func reconcileLocked() throws -> ReconcileResult {
        var removed: [Int32] = []
        var desired = false
        for r in store.list() {
            if probe.isLive(r) {
                desired = desired || r.held
            } else {
                store.remove(pid: r.pid)
                removed.append(r.pid)
            }
        }
        let current = try power.sleepDisabled()
        if current != desired {
            try power.setSleepDisabled(desired)
        }
        return ReconcileResult(removed: removed, desired: desired, changed: current != desired)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LidlessError.command("can't open lock \(lockURL.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LidlessError.command("can't lock \(lockURL.path)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
