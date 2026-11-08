import Darwin
import Foundation
import LidlessCore

/// `lidless [--sleep-after] <cmd> [args…]`
final class Wrapper {
    static let tickInterval: TimeInterval = 30

    let paths: LidlessPaths
    let store: HoldStore
    let reconciler: Reconciler
    let power: PowerControl
    let readings: PowerReadingsSource
    let notifier: Notifier
    let config: Config
    let sleepAfter: Bool

    var record: HoldRecord
    var childPid: pid_t = 0
    var wroteOnce = false
    var manuallyReleased = false
    var warnedPrivilege = false
    var timer: DispatchSourceTimer?
    var signalSources: [DispatchSourceSignal] = []

    init(argv: [String], sleepAfter: Bool) {
        paths = LidlessPaths.standard()
        store = HoldStore(paths: paths)
        power = PmsetPowerControl()
        readings = SystemReadings()
        notifier = OsascriptNotifier()
        config = Config.load(from: paths.config)
        reconciler = Reconciler(store: store, power: power, probe: SystemProcessProbe(), lockURL: paths.lock)
        self.sleepAfter = sleepAfter
        record = HoldRecord(
            pid: getpid(), command: argv.joined(separator: " "),
            kind: ClaudeInjection.isClaude(argv[0]) ? .claude : .plain,
            startedAt: Date(), held: false, reason: .active)
    }

    func run(argv: [String]) -> Never {
        do { try paths.ensure() } catch { stderrLine("can't create \(paths.home.path): \(error)") }

        var childArgs = argv
        if record.kind == .claude {
            if argv.contains("--bg") {
                stderrLine("warning: `claude --bg` detaches immediately, so lidless can't keep it awake")
            }
            do {
                childArgs = [argv[0]] + (try ClaudeInjection.inject(args: Array(argv.dropFirst()),
                                                                   lidlessPath: selfExecutablePath()))
            } catch {
                stderrLine("\(error) — running without idle detection")
                record.kind = .plain
            }
        }

        installSignalHandlers()

        let env = ProcessInfo.processInfo.environment
            .merging(["LIDLESS_ACTIVITY_FILE": store.activityURL(pid: record.pid).path,
                      "LIDLESS_PID": String(record.pid)]) { $1 }
        do {
            childPid = try spawn(childArgs, env: env)
        } catch {
            stderrLine("\(argv[0]): \(error)")
            exit(127)
        }
        record.childPid = childPid

        tick()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .seconds(2))
        t.setEventHandler { self.tick() }
        t.resume()
        timer = t

        let pid = childPid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async { self.finish(status: status) }
        }
        dispatchMain()
    }

    func tick() {
        if wroteOnce && !store.exists(pid: record.pid) {
            manuallyReleased = true  // `lidless release` removed our hold
        }
        let current = readings.read()
        let decision = decide(DecisionInput(
            kind: record.kind, startedAt: record.startedAt, activity: store.readActivity(pid: record.pid),
            readings: current, config: config, now: Date(), manuallyReleased: manuallyReleased))

        // Send before releasing: with the lid shut the Mac sleeps right after, and the alert would never leave.
        if let kind = Alerts.kindForTransition(wasHeld: record.held, decision: decision) {
            sendAlert(kind, readings: current, exitCode: nil)
        }

        if record.held, !decision.held, decision.reason.isSafety, config.notify {
            let why = decision.reason == .lowBattery ? "battery is low" : "the Mac is running hot"
            notifier.notify("Letting the Mac sleep: \(why).")
        }
        record.held = decision.held
        record.reason = decision.reason
        record.effective = true
        do {
            try reconciler.update(record)
        } catch {
            record.effective = false
            try? store.write(record)
            if !warnedPrivilege {
                stderrLine("\(error). Running without keep-awake.")
                warnedPrivilege = true
            }
        }
        wroteOnce = true
    }

    func finish(status: Int32) -> Never {
        timer?.cancel()
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if Alerts.shouldSendFinished(duration: Date().timeIntervalSince(record.startedAt), config: config.alerts) {
            sendAlert(.finished, readings: readings.read(), exitCode: exitCode)
        }
        do {
            let result = try reconciler.remove(pid: record.pid)
            if sleepAfter, !result.desired {
                try power.sleepNow()
            }
        } catch {
            if !warnedPrivilege { stderrLine("\(error)") }
        }
        exit(exitCode)
    }

    func sendAlert(_ kind: AlertKind, readings r: Readings, exitCode: Int32?) {
        lidless.sendAlert(kind, record: record, readings: r, exitCode: exitCode, config: config)
    }

    /// The terminal delivers SIGINT to the whole foreground process group, so the child already
    /// gets it; lidless just ignores it. SIGTERM/SIGHUP are forwarded explicitly.
    func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                if self.childPid > 0 { kill(self.childPid, sig) }
            }
            src.resume()
            signalSources.append(src)
        }
        // A hook saw activity resume after an idle release: re-evaluate now.
        signal(SIGUSR1, SIG_IGN)
        let wake = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        wake.setEventHandler { self.tick() }
        wake.resume()
        signalSources.append(wake)
    }

    func spawn(_ argv: [String], env: [String: String]) throws -> pid_t {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Child gets default dispositions and an empty mask, not our SIG_IGNs.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGUSR1] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], nil, &attr, cArgs, cEnv)
        guard rc == 0 else { throw LidlessError.command(String(cString: strerror(rc))) }
        return pid
    }
}
