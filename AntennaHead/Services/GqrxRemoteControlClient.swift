import Foundation
import SharedLogging

/// One bookmark as reported by Gqrx's `\get_bookmarks` remote-control command.
struct GqrxBookmark: Sendable, Equatable {
    var frequencyHz: Int64
    var name: String
    var modulation: String
    var bandwidthHz: Int
    var tags: [String]
}

/// One sample of a running Gqrx's state, delivered from the poll loop.
struct GqrxSnapshot: Sendable {
    var reachable = false
    var frequencyHz: Int64?
    var mode: String?
    var passbandHz: Int?
    var filterShape: Int?
    var hasFilterShape = false
    var squelchDBFS: Double?
    var afGainDB: Double?
    var rfGainName = ""
    var rfGainValue: Double?
    var signalDBFS: Double?
    var muted: Bool?
    /// Gqrx's DSP / receiver run state (`u DSP`) — nil until first polled.
    var dspRunning: Bool?
    var modeList: [String] = []
    var bookmarks: [GqrxBookmark] = []

    /// True when Gqrx carries the device-control commands (PR #1446).
    var hasDeviceControl = false
    var inputDeviceList: [String] = []     // human-readable labels
    var inputDevice = ""                    // current gr-osmosdr device string
    var outputDeviceList: [String] = []     // audio output device names
    var outputDevice = ""
}

/// A client for Gqrx's rigctl-style TCP remote-control protocol
/// (default `127.0.0.1:7356`, enabled in Gqrx via *Tools ▸ Remote control*).
///
/// Deliberately **not** an `actor` and **not** built on Swift concurrency: it
/// owns one serial `DispatchQueue` and a plain blocking BSD socket with short
/// send/receive timeouts, exactly like `RTLSDRStatusListener`. Every public
/// call is fire-and-forget onto that queue, so a slow or dead Gqrx can never
/// stall the main actor or the web server's task pool. State comes back through
/// the `onSnapshot` callback (invoked on the queue).
///
/// Implements only what the "Listen to Gqrx" web panel needs: frequency, demod
/// mode + passband, filter shape (Gqrx PR #1463), the `SQL` / `AF` /
/// `<name>_GAIN` levels, signal strength, mute, and bookmark download + recall
/// (Gqrx PR #1464).
final class GqrxRemoteControlClient: @unchecked Sendable {
    /// Called ~1×/s on the client's own queue with the latest Gqrx state.
    var onSnapshot: ((GqrxSnapshot) -> Void)?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.dsward.AntennaHead.GqrxRemoteControlClient")

    private var fd: Int32 = -1
    private var readBuffer = Data()
    private var pollTimer: DispatchSourceTimer?
    private var running = false

    // Discovered once per connection.
    private var hasFilterShape = false
    private var rfGainName = ""
    private var modeList: [String] = []
    private var bookmarks: [GqrxBookmark] = []
    private var hasDeviceControl = false
    private var inputDeviceList: [String] = []
    private var outputDeviceList: [String] = []
    private var currentInputDevice = ""
    private var currentOutputDevice = ""

    init(host: String = "127.0.0.1", port: UInt16 = 7356) {
        self.host = host
        self.port = port
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.discover()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.pollTimer = timer
        }
    }

    func stop() {
        // Strong `self` for this one-shot cleanup so the timer is actually
        // cancelled and the socket closed even if the owner drops its
        // reference the instant it calls stop().
        queue.async {
            self.running = false
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.closeSocket()
        }
    }

    // MARK: Writes (fire-and-forget)

    func setFrequency(_ hz: Int64)              { send("F \(hz)") }
    func setMode(_ mode: String, passbandHz: Int) { send("M \(mode) \(max(0, passbandHz))") }
    func setFilterShape(_ shape: Int)           { send("L FILTER_SHAPE \(shape)") }
    func setLevel(_ name: String, _ value: Double) { send("L \(name) \(String(format: "%.2f", value))") }
    func setMuted(_ on: Bool)                   { send("U MUTE \(on ? 1 : 0)") }
    func setDSP(_ on: Bool)                     { send("U DSP \(on ? 1 : 0)") }
    func applyBookmarkFrequency(_ hz: Int64)    { send("\\set_bookmark_freq \(hz)") }
    func setInputDevice(_ dev: String)         { send("\\set_input_device \(dev)") }
    func setOutputDevice(_ dev: String)        { send("\\set_output_device \(dev)") }

    private func send(_ command: String) {
        queue.async { [weak self] in _ = self?.exchange(command) }
    }

    // MARK: Socket

    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        readBuffer.removeAll(keepingCapacity: true)

        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)   // "127.0.0.1"

        let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok { close(s); return false }
        fd = s
        return true
    }

    private func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
        readBuffer.removeAll(keepingCapacity: true)
    }

    /// Send one command, read `lineCount` reply lines. Any failure closes the
    /// socket (next call reconnects) and returns `nil`.
    @discardableResult
    private func exchange(_ command: String, lineCount: Int = 1) -> [String]? {
        guard ensureConnected() else { return nil }

        let payload = Array((command + "\n").utf8)
        let sent = payload.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, raw.count)
        }
        guard sent == payload.count else { closeSocket(); return nil }

        var lines: [String] = []
        while lines.count < lineCount {
            guard let line = readLine() else { closeSocket(); return lines.isEmpty ? nil : lines }
            lines.append(line)
        }
        return lines
    }

    private func readLines(_ count: Int) -> [String] {
        var out: [String] = []
        for _ in 0..<max(0, count) {
            guard let line = readLine() else { break }
            out.append(line)
        }
        return out
    }

    private func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let lineData = readBuffer[readBuffer.startIndex..<nl]
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }   // 0 = peer closed, <0 = error/timeout
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func rprtOK(_ lines: [String]?) -> Bool {
        lines?.first?.trimmingCharacters(in: .whitespaces) == "RPRT 0"
    }

    // MARK: Discovery + poll

    private func discover() {
        guard exchange("_") != nil else { return }

        discoverDevices()

        let levels = exchange("l ?")?.first?.split(separator: " ").map(String.init) ?? []
        hasFilterShape = levels.contains { $0.caseInsensitiveCompare("FILTER_SHAPE") == .orderedSame }
        rfGainName = levels.first { $0.uppercased().hasSuffix("_GAIN") }.map { String($0.dropLast(5)) } ?? ""
        modeList = exchange("M ?")?.first?.split(separator: " ").map(String.init) ?? []
        bookmarks = fetchBookmarks() ?? []
    }

    /// Device control (Gqrx PR #1446), fetched **once per connection** — every
    /// `\get_*_device*` command in #1446 re-enumerates the SDR hardware, which
    /// stalls for several seconds while a device is open, so this must not run
    /// in the 1 Hz poll. Runs right after `_` on a fresh connection, before any
    /// other command, so replies can't batch up behind it.
    private func discoverDevices() {
        let inList = deviceListReply("\\get_input_device_list", timeoutSec: 12)
        hasDeviceControl = !inList.isEmpty && inList != ["RPRT 1"]
        guard hasDeviceControl else {
            inputDeviceList = []; outputDeviceList = []
            currentInputDevice = ""; currentOutputDevice = ""
            return
        }
        inputDeviceList = inList
        outputDeviceList = deviceListReply("\\get_output_device_list", timeoutSec: 10)
            .filter { $0 != "RPRT 1" }
        currentInputDevice  = exchangeLong("\\get_input_device")
        currentOutputDevice = exchangeLong("\\get_output_device")
    }

    /// Like `exchange(_, lineCount: 1)` but with a long read window, for the
    /// #1446 getters that re-probe hardware. Returns "" on failure.
    private func exchangeLong(_ cmd: String) -> String {
        let lines = deviceListReply(cmd, timeoutSec: 10)
        return (lines.first ?? "") == "RPRT 1" ? "" : (lines.first ?? "")
    }

    /// Send a command whose reply is an uncounted newline list, and return the
    /// lines. One `read()` — Gqrx writes the whole (short) list in one go —
    /// with `timeoutSec` applied just for this call.
    private func deviceListReply(_ cmd: String, timeoutSec: Int) -> [String] {
        guard ensureConnected() else { return [] }
        readBuffer.removeAll(keepingCapacity: true)

        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var back = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &back, socklen_t(MemoryLayout<timeval>.size))
        }

        let payload = Array((cmd + "\n").utf8)
        guard payload.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == payload.count
        else { closeSocket(); return [] }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { closeSocket(); return [] }
        return String(decoding: chunk[0..<n], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    }

    private func fetchBookmarks() -> [GqrxBookmark]? {
        guard let head = exchange("\\get_bookmarks", lineCount: 1),
              let count = head.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        guard count > 0 else { return [] }
        return readLines(count).compactMap { line in
            let f = line.components(separatedBy: "|")
            guard f.count >= 5, let hz = Int64(f[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            return GqrxBookmark(
                frequencyHz: hz,
                name: f[1].trimmingCharacters(in: .whitespaces),
                modulation: f[2].trimmingCharacters(in: .whitespaces),
                bandwidthHz: Int(f[3].trimmingCharacters(in: .whitespaces)) ?? 0,
                tags: f[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }

    /// Parse a one-line numeric reply, rejecting `nan` / `inf` — Gqrx reports
    /// non-finite dBFS for `STRENGTH` (and sometimes `SQL`/`AF`) when the DSP
    /// isn't producing a signal, and a non-finite `Double` later fed to
    /// `JSONSerialization` raises an uncatchable ObjC exception.
    private func doubleReply(_ cmd: String) -> Double? {
        guard let v = exchange(cmd)?.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              v.isFinite else { return nil }
        return v
    }

    private func poll() {
        guard running else { return }

        // Rediscover (and refetch bookmarks) if the connection had dropped.
        if fd < 0 { discover() }

        var snap = GqrxSnapshot()
        snap.hasFilterShape = hasFilterShape
        snap.rfGainName = rfGainName
        snap.modeList = modeList
        snap.bookmarks = bookmarks
        snap.hasDeviceControl = hasDeviceControl
        snap.inputDeviceList = inputDeviceList
        snap.outputDeviceList = outputDeviceList

        let freq = exchange("f")?.first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        snap.reachable = (freq != nil)
        snap.frequencyHz = freq

        if let m = exchange("m", lineCount: 2), m.count == 2 {
            snap.mode = m[0].trimmingCharacters(in: .whitespaces)
            snap.passbandHz = Int(m[1].trimmingCharacters(in: .whitespaces))
        }
        snap.signalDBFS = doubleReply("l STRENGTH")
        if hasFilterShape {
            snap.filterShape = exchange("l FILTER_SHAPE")?.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        snap.squelchDBFS = doubleReply("l SQL")
        snap.afGainDB = doubleReply("l AF")
        if !rfGainName.isEmpty { snap.rfGainValue = doubleReply("l \(rfGainName)_GAIN") }
        if let mu = exchange("u MUTE")?.first?.trimmingCharacters(in: .whitespaces) { snap.muted = (mu == "1") }
        if let dsp = exchange("u DSP")?.first?.trimmingCharacters(in: .whitespaces) { snap.dspRunning = (dsp == "1") }
        // Cached from discoverDevices() — never re-queried in the poll (#1446's
        // getters re-probe hardware and would stall the 1 Hz loop).
        snap.inputDevice = currentInputDevice
        snap.outputDevice = currentOutputDevice

        onSnapshot?(snap)
    }
}
