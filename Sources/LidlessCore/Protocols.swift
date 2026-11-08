import Foundation

public enum LidlessError: Error, CustomStringConvertible {
    /// `sudo -n pmset …` failed — usually the sudoers rule isn't installed.
    case privilege(String)
    case command(String)

    public var description: String {
        switch self {
        case .privilege(let msg): return "can't change sleep settings (\(msg)); run `lidless setup`"
        case .command(let msg): return msg
        }
    }
}

/// The global `SleepDisabled` power flag.
public protocol PowerControl {
    func sleepDisabled() throws -> Bool
    func setSleepDisabled(_ on: Bool) throws
    func sleepNow() throws
}

public protocol PowerReadingsSource {
    func read() -> Readings
}

public protocol ProcessProbe {
    /// True if the hold's owner is still running: the lidless wrapper, or for an adopted hold the
    /// claude process itself (the name check guards against pid reuse).
    func isLive(_ hold: HoldRecord) -> Bool
}

public protocol Notifier {
    func notify(_ message: String)
}
