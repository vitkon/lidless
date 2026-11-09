import Foundation
import Testing
@testable import LidsomniaCore

private func facts(legacyHome: Bool = true, home: Bool = false, overridden: Bool = false, live: Bool = false,
                   legacyAgent: Bool = false, agent: Bool = false) -> Migration.Facts {
    Migration.Facts(legacyHomeExists: legacyHome, homeExists: home, homeOverridden: overridden,
                    legacyHoldsLive: live, legacyAgentExists: legacyAgent, agentExists: agent)
}

@Suite struct MigrationTests {
    @Test func movesOldDataDirWhenNewOneIsMissing() {
        #expect(Migration.plan(facts()).moveHome)
    }

    @Test func leavesDataDirAloneWhenItCantOrNeedNotMove() {
        #expect(!Migration.plan(facts(home: true)).moveHome)
        #expect(!Migration.plan(facts(overridden: true)).moveHome)
        #expect(!Migration.plan(facts(live: true)).moveHome)
        #expect(!Migration.plan(facts(legacyHome: false)).moveHome)
    }

    @Test func replacesOldWatchdog() {
        #expect(Migration.plan(facts(legacyAgent: true)).replaceAgent)
        #expect(Migration.plan(facts(legacyAgent: true, agent: true)).replaceAgent)
        #expect(Migration.plan(facts(legacyHome: false)).isEmpty)
    }

    @Test func holdPidsIgnoreActivityFiles() {
        #expect(Migration.holdPids(in: ["12.json", "12.activity", "x.json", "99.json"]) == [12, 99])
    }

    @Test func oldAliasPointsAtNewBinary() {
        let both: (String) -> Bool = { _ in true }
        #expect(Migration.preferredBinary(invoked: "/opt/homebrew/bin/lidless", exists: both) == "/opt/homebrew/bin/lidsomnia")
        #expect(Migration.preferredBinary(invoked: "/opt/homebrew/bin/lidless", exists: { _ in false }) == "/opt/homebrew/bin/lidless")
        #expect(Migration.preferredBinary(invoked: "/opt/homebrew/bin/lidsomnia", exists: both) == "/opt/homebrew/bin/lidsomnia")
    }
}
