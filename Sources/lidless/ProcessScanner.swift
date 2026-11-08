import Darwin
import Foundation
import LidlessCore

/// Darwin process inspection for auto-detect and liveness checks.
enum ProcessScanner {
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// argv via sysctl KERN_PROCARGS2: [argc: Int32][exec path\0][padding \0…][argv[0]\0 … ].
    static func argv(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while i < size && args.count < argc {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func ppid(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// All processes that look like Claude Code sessions.
    static func claudeProcesses() -> [ProcInfo] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [ProcInfo] = []
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 && pid != getpid() {
            guard let path = path(pid) else { continue }
            let base = (path as NSString).lastPathComponent
            // Cheap prefilter before reading argv for every process on the system.
            guard path.contains("claude") || base.hasPrefix("node") else { continue }
            let args = argv(pid)
            guard AutoDetect.isClaudeProcess(path: path, argv: args) else { continue }
            out.append(ProcInfo(pid: pid, ppid: ppid(pid) ?? 0, path: path, argv: args, cwd: cwd(pid)))
        }
        return out
    }
}
