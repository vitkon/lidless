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
            .merging(["LIDLESS_ACTIVITY_FILE": store.activityURL(pid: record.pid).path]) { $1 }
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
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        let pid = childPid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async { self?.finish(status: status) }
        }
        dispatchMain()
    }

    func tick() {
        if wroteOnce && !store.exists(pid: record.pid) {
            manuallyReleased = true  // `lidless release` removed our hold
        }
        let decision = decide(DecisionInput(
            kind: record.kind, startedAt: record.startedAt, activity: store.readActivity(pid: record.pid),
            readings: readings.read(), config: config, now: Date(), manuallyReleased: manuallyReleased))

        if record.held, !decision.held, decision.reason.isSafety, config.notify {
            let why = decision.reason == .lowBattery ? "battery is low" : "the Mac is running hot"
            notifier.notify("Letting the Mac sleep: \(why).")
        }
        record.held = decision.held
        record.reason = decision.reason
        do {
            try reconciler.update(record)
        } catch {
            if !warnedPrivilege {
                stderrLine("\(error). Running without keep-awake.")
                warnedPrivilege = true
            }
        }
        wroteOnce = true
    }

    func finish(status: Int32) -> Never {
        timer?.cancel()
        do {
            let result = try reconciler.remove(pid: record.pid)
            if sleepAfter, !result.desired {
                try power.sleepNow()
            }
        } catch {
            if !warnedPrivilege { stderrLine("\(error)") }
        }
        if (status & 0x7f) == 0 {
            exit((status >> 8) & 0xff)  // WIFEXITED → WEXITSTATUS
        }
        exit(128 + (status & 0x7f))  // WTERMSIG
    }

    /// The terminal delivers SIGINT to the whole foreground process group, so the child already
    /// gets it; lidless just ignores it. SIGTERM/SIGHUP are forwarded explicitly.
    func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                if let pid = self?.childPid, pid > 0 { kill(pid, sig) }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func spawn(_ argv: [String], env: [String: String]) throws -> pid_t {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Child gets default dispositions and an empty mask, not our SIG_IGNs.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] { sigaddset(&defaults, s) }
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
