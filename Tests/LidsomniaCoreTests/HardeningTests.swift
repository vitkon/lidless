import Foundation
import Testing
@testable import LidsomniaCore

@Suite struct HardeningTests {
    private func record(held: Bool, reason: HoldReason) -> HoldRecord {
        HoldRecord(pid: 1, command: "claude", kind: .claude, startedAt: Date(timeIntervalSince1970: 0),
                   held: held, reason: reason)
    }

    @Test func recordsWrittenByV1DecodeAsEffective() throws {
        let v1 = #"{"command":"x","held":true,"kind":"plain","pid":7,"reason":"active","startedAt":0}"#
        let r = try HoldStore.decoder.decode(HoldRecord.self, from: Data(v1.utf8))
        #expect(r.effective)
    }

    @Test func effectiveRoundTrips() throws {
        var r = record(held: true, reason: .active)
        r.effective = false
        let back = try HoldStore.decoder.decode(HoldRecord.self, from: HoldStore.encoder.encode(r))
        #expect(back.effective == false)
    }

    @Test func busyHookWakesAnIdleReleasedWrapper() {
        #expect(shouldWakeWrapper(record: record(held: false, reason: .idle), state: .busy))
    }

    @Test func busyHookDoesNotWakeAHoldingWrapper() {
        #expect(!shouldWakeWrapper(record: record(held: true, reason: .active), state: .busy))
    }

    @Test func idleHookNeverWakes() {
        #expect(!shouldWakeWrapper(record: record(held: false, reason: .idle), state: .idle))
    }

    @Test func manualReleaseIsNotWoken() {
        #expect(!shouldWakeWrapper(record: record(held: false, reason: .manual), state: .busy))
    }

    @Test func missingRecordIsNotWoken() {
        #expect(!shouldWakeWrapper(record: nil, state: .busy))
    }
}
