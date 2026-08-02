import Foundation
import SharedLogging

/// Scans for and terminates any orphaned AntennaHead helper processes from a
/// previous session before new ones are launched, preventing port-binding
/// conflicts. Also provides port-availability waiting used during restarts.
///
/// Uses sysctl(KERN_PROC_ALL) — the same approach as LocalRadio — but
/// auto-terminates rather than alerting the user.
enum HelperProcessPreflight {

    // Helper executables that bind exclusive ports, matched against kinfo_proc.kp_proc.p_comm
    // (p_comm is truncated to MAXCOMLEN=15 significant chars; both names fit exactly).
    private static let helperNames = ["LiveAudioServer", "shairport-sync"]

    /// Finds all processes matching the known helper names (excluding this
    /// process), sends SIGTERM, waits up to 2 seconds for graceful exit,
    /// then SIGKILLs survivors. Silent no-op if sysctl is blocked.
    static func terminateOrphanedHelpers() async {
        let pids = helperNames.flatMap { allPIDs(named: $0) }
        guard !pids.isEmpty else { return }

        await LogStore.shared.log(.info, source: "HelperProcessPreflight",
            "terminating \(pids.count) orphaned helper(s): PIDs \(pids)")
        for pid in pids {
            if kill(pid, SIGTERM) != 0 {
                await LogStore.shared.log(.warning, source: "HelperProcessPreflight",
                    "SIGTERM PID \(pid) failed (errno=\(errno)) — may be unkillable")
            }
        }

        // Use isActuallyRunning (which doesn't conflate EPERM with "not running")
        // so we don't bail out early when kill() lacked permission but the process
        // is still alive and holding its ports.
        let deadline = Date().addingTimeInterval(2.0)
        var alive = pids.filter { isActuallyRunning($0) }
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            alive = alive.filter { isActuallyRunning($0) }
        }
        for pid in alive {
            await LogStore.shared.log(.info, source: "HelperProcessPreflight", "SIGKILL PID \(pid)")
            kill(pid, SIGKILL)
        }
        if !alive.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Polls until the UDP port is available to bind, up to `timeout` seconds.
    /// If it's still in use at the deadline, logs a warning and returns so the
    /// caller can attempt the launch (and handle its own bind failure).
    static func waitForUDPPortFree(_ port: UInt16, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isUDPPortFree(port) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !isUDPPortFree(port) {
            await LogStore.shared.log(.warning, source: "HelperProcessPreflight",
                "UDP port \(port) still in use after \(timeout)s; proceeding anyway")
        }
    }

    /// Polls until the TCP port is available to bind, up to `timeout` seconds.
    /// Used to confirm shairport-sync (port 5000) has fully released before a
    /// replacement is launched. No-op if the port is already free.
    static func waitForTCPPortFree(_ port: UInt16, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isTCPPortFree(port) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !isTCPPortFree(port) {
            await LogStore.shared.log(.warning, source: "HelperProcessPreflight",
                "TCP port \(port) still in use after \(timeout)s; proceeding anyway")
        }
    }

    // MARK: - Private

    /// Returns all PIDs whose p_comm matches `name`, excluding this process.
    /// Returns [] silently if sysctl is unavailable.
    private static func allPIDs(named name: String) -> [pid_t] {
        var size: size_t = 0
        // namelen=3: {CTL_KERN, KERN_PROC, KERN_PROC_ALL}. The trailing 0 is
        // padding (matching LocalRadio's sizeof(name)/sizeof(*name)-1 = 3 pattern).
        // Passing 4 would give the kernel an unexpected 4th element and return EINVAL.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var bufSize = count * stride
        guard sysctl(&mib, 3, &procs, &bufSize, nil, 0) == 0 else { return [] }

        let actualCount = bufSize / stride
        let myPID = getpid()
        var result: [pid_t] = []
        for i in 0..<actualCount {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0, pid != myPID else { continue }
            let comm = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw in
                String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            if comm == name { result.append(pid) }
        }
        return result
    }

    /// Returns true if the process exists (still running or a zombie waiting to be reaped).
    /// Treats both success AND EPERM as "running" — EPERM means we can't signal it
    /// but it IS alive; only ESRCH means the process is truly gone.
    private static func isActuallyRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func isUDPPortFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return true }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func isTCPPortFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return true }
        defer { close(sock) }
        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
