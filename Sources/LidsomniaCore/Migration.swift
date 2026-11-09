import Foundation

/// lidsomnia used to be called lidless. Installs from then keep working: this decides what to
/// move over from the old names (`~/.lidless`, the `com.lidless.watchdog` launch agent).
public enum Migration {
    public static let legacyName = "lidless"
    public static let legacyHomeName = ".lidless"
    public static let legacyAgentLabel = "com.lidless.watchdog"
    public static let legacySudoersPath = "/etc/sudoers.d/lidless"

    public struct Facts: Equatable, Sendable {
        public var legacyHomeExists: Bool
        public var homeExists: Bool
        /// `$LIDSOMNIA_HOME` is set, so the data dir isn't the default one to move into.
        public var homeOverridden: Bool
        /// An old `lidless` wrapper is still running and writing into `~/.lidless/holds`.
        public var legacyHoldsLive: Bool
        public var legacyAgentExists: Bool
        public var agentExists: Bool

        public init(legacyHomeExists: Bool, homeExists: Bool, homeOverridden: Bool, legacyHoldsLive: Bool,
                    legacyAgentExists: Bool, agentExists: Bool) {
            self.legacyHomeExists = legacyHomeExists
            self.homeExists = homeExists
            self.homeOverridden = homeOverridden
            self.legacyHoldsLive = legacyHoldsLive
            self.legacyAgentExists = legacyAgentExists
            self.agentExists = agentExists
        }
    }

    public struct Plan: Equatable, Sendable {
        public var moveHome: Bool
        /// Install the new watchdog (if missing) and remove the old one.
        public var replaceAgent: Bool
        public var isEmpty: Bool { !moveHome && !replaceAgent }
    }

    public static func plan(_ f: Facts) -> Plan {
        Plan(moveHome: f.legacyHomeExists && !f.homeExists && !f.homeOverridden && !f.legacyHoldsLive,
             replaceAgent: f.legacyAgentExists)
    }

    /// Pids of hold files (`<pid>.json`) in a holds directory listing.
    public static func holdPids(in filenames: [String]) -> [Int32] {
        filenames.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return Int32(name.dropLast(5))
        }
    }

    /// The binary to point the watchdog and hooks at. When run through the old `lidless` alias,
    /// prefer the `lidsomnia` binary next to it so nothing depends on the alias.
    public static func preferredBinary(invoked: String, exists: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: invoked)
        guard url.lastPathComponent == legacyName else { return invoked }
        let sibling = url.deletingLastPathComponent().appendingPathComponent("lidsomnia").path
        return exists(sibling) ? sibling : invoked
    }
}
