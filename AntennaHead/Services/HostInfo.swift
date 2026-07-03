import Foundation

/// LAN-reachable identity of this Mac, used to build shareable web-UI URLs and
/// the Bonjour advertisement name. Ported from LocalRadio's AppDelegate
/// (`localHostIPString` / `configureServices` Bonjour-name lookup).
enum HostInfo {
    /// Primary LAN IPv4 address, preferring en0 (built-in/primary interface),
    /// then en1, then any other non-loopback interface. Nil when offline.
    static func lanIPAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var en0: String?
        var en1: String?
        var other: String?

        var cursor = interfaces
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard let ip = String(validatingCString: inet_ntoa(addr)) else { continue }
            switch name {
            case "lo0": break
            case "en0": en0 = ip
            case "en1": en1 = ip
            default: if other == nil { other = ip }
            }
        }
        return en0 ?? en1 ?? other
    }

    /// This Mac's Bonjour `.local` host name (e.g. "Mac-mini.local"), from
    /// `gethostname` — fast and non-blocking, unlike `Host` DNS lookups.
    /// Nil when the system host name is not a `.local` name.
    static func bonjourHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0,
              let name = String(validatingCString: buffer) else {
            return nil
        }
        return name.hasSuffix(".local") ? name : nil
    }

    /// Host to embed in shareable URLs: the LAN IP when available (matches
    /// LocalRadio's shared-URL behavior — resolvable from any LAN device),
    /// otherwise the `.local` name, otherwise localhost.
    static func shareableHost() -> String {
        lanIPAddress() ?? bonjourHostName() ?? "localhost"
    }
}
