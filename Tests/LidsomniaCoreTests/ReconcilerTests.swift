import Foundation
import Testing
@testable import LidsomniaCore

final class FakePower: PowerControl, @unchecked Sendable {
    var disabled = false
    var setCalls: [Bool] = []
    var sleepNowCalls = 0
    var failSet = false

    func sleepDisabled() throws -> Bool { disabled }
    func setSleepDisabled(_ on: Bool) throws {
        if failSet { throw LidsomniaError.privilege("no sudoers rule") }
        setCalls.append(on)
        disabled = on
    }
    func sleepNow() throws { sleepNowCalls += 1 }
}

final class FakeProbe: ProcessProbe, @unchecked Sendable {
    var alive: Set<Int32> = []
    func isLive(_ hold: HoldRecord) -> Bool { alive.contains(hold.pid) }
}

private func tempHome() -> LidsomniaPaths {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidsomnia-test-\(UUID().uuidString)")
    let paths = LidsomniaPaths(home: dir)
    try! paths.ensure()
    return paths
}

private func record(_ pid: Int32, held: Bool) -> HoldRecord {
    HoldRecord(pid: pid, command: "sleep 1", kind: .plain, startedAt: Date(timeIntervalSince1970: 0),
               held: held, reason: held ? .active : .idle)
}

@Suite struct HoldStoreTests {
    @Test func roundTripsRecordsAndActivity() throws {
        let store = HoldStore(paths: tempHome())
        let r = record(42, held: true)
        try store.write(r)
        #expect(try store.read(pid: 42) == r)
        #expect(store.list() == [r])

        let a = Activity(state: .busy, at: Date(timeIntervalSince1970: 123))
        try store.writeActivity(a, to: store.activityURL(pid: 42))
        #expect(store.readActivity(pid: 42) == a)

        store.remove(pid: 42)
        #expect(store.list().isEmpty)
        #expect(store.readActivity(pid: 42) == nil)
    }

    @Test func listSkipsCorruptFiles() throws {
        let paths = tempHome()
        let store = HoldStore(paths: paths)
        try store.write(record(1, held: true))
        try Data("not json".utf8).write(to: paths.holds.appendingPathComponent("2.json"))
        #expect(store.list().map(\.pid) == [1])
    }
}

@Suite struct ReconcilerTests {
    func make() -> (Reconciler, HoldStore, FakePower, FakeProbe) {
        let paths = tempHome()
        let store = HoldStore(paths: paths)
        let power = FakePower()
        let probe = FakeProbe()
        return (Reconciler(store: store, power: power, probe: probe, lockURL: paths.lock), store, power, probe)
    }

    @Test func liveHeldHoldDisablesSleep() throws {
        let (rec, _, power, probe) = make()
        probe.alive = [10]
        try rec.update(record(10, held: true))
        #expect(power.disabled)
        #expect(power.setCalls == [true])
    }

    @Test func noChangeMeansNoPmsetCall() throws {
        let (rec, _, power, probe) = make()
        probe.alive = [10]
        try rec.update(record(10, held: true))
        try rec.update(record(10, held: true))
        #expect(power.setCalls == [true])
    }

    @Test func lastHolderReleasingReenablesSleep() throws {
        let (rec, _, power, probe) = make()
        probe.alive = [10, 11]
        try rec.update(record(10, held: true))
        try rec.update(record(11, held: true))
        try rec.remove(pid: 10)
        #expect(power.disabled)
        try rec.remove(pid: 11)
        #expect(!power.disabled)
        #expect(power.setCalls == [true, false])
    }

    @Test func releasedHoldDoesNotKeepAwake() throws {
        let (rec, _, power, probe) = make()
        probe.alive = [10, 11]
        try rec.update(record(10, held: true))
        try rec.update(record(11, held: false))
        try rec.update(record(10, held: false))
        #expect(!power.disabled)
    }

    @Test func reapRemovesDeadHoldsAndResetsFlag() throws {
        let (rec, store, power, probe) = make()
        probe.alive = [10]
        try rec.update(record(10, held: true))
        probe.alive = []  // wrapper was kill -9'd
        let result = try rec.reconcile()
        #expect(result.removed == [10])
        #expect(store.list().isEmpty)
        #expect(!power.disabled)
    }

    @Test func reapResetsStaleFlagWithNoHolds() throws {
        let (rec, _, power, _) = make()
        power.disabled = true
        try rec.reconcile()
        #expect(!power.disabled)
    }

    @Test func releaseAllClearsHoldsAndFlag() throws {
        let (rec, store, power, probe) = make()
        probe.alive = [10, 11]
        try rec.update(record(10, held: true))
        try rec.update(record(11, held: true))
        try rec.releaseAll()
        #expect(store.list().isEmpty)
        #expect(!power.disabled)
    }

    @Test func privilegeErrorPropagatesButRecordIsWritten() throws {
        let (rec, store, power, probe) = make()
        probe.alive = [10]
        power.failSet = true
        #expect(throws: LidsomniaError.self) { try rec.update(record(10, held: true)) }
        #expect(try store.read(pid: 10) != nil)
    }
}
