import Foundation
import Network

@MainActor
@Observable
final class AntennaHeadHTTPServer {
    let httpPort: UInt16 = 8090
    let httpsPort: UInt16 = 8094
    private(set) var isRunning = false
    private(set) var httpsEnabled = false

    /// Retained for compatibility with code that reads `httpServer.port`.
    var port: UInt16 { httpPort }

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "com.dsward.AntennaHead.HTTPServer", qos: .userInitiated)

    func start(tlsIdentity: sec_identity_t? = nil, auth: HTTPAuthCredentials.Credentials? = nil) {
        stop()
        do {
            httpListener = try makeListener(port: httpPort, tlsIdentity: nil, auth: auth)
            httpListener?.start(queue: queue)
            if let tlsIdentity {
                httpsListener = try makeListener(port: httpsPort, tlsIdentity: tlsIdentity, auth: auth)
                httpsListener?.start(queue: queue)
                httpsEnabled = true
            }
            isRunning = true
        } catch {
            print("AntennaHeadHTTPServer failed to start: \(error)")
            stop()
        }
    }

    func stop() {
        httpListener?.cancel()
        httpsListener?.cancel()
        httpListener = nil
        httpsListener = nil
        isRunning = false
        httpsEnabled = false
    }

    private func makeListener(port: UInt16, tlsIdentity: sec_identity_t?, auth: HTTPAuthCredentials.Credentials?) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        let params: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, auth: auth)
        }
        return listener
    }

    nonisolated private func handle(_ connection: NWConnection, auth: HTTPAuthCredentials.Credentials?) {
        connection.start(queue: queue)
        receive(on: connection, accumulator: Data(), auth: auth)
    }

    nonisolated private func receive(on connection: NWConnection, accumulator: Data, auth: HTTPAuthCredentials.Credentials?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulator
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let request = self.parseRequest(buffer) {
                let response = self.route(request, auth: auth)
                self.send(response, on: connection)
                return
            }

            if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel()
                return
            }

            self.receive(on: connection, accumulator: buffer, auth: auth)
        }
    }

    nonisolated private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: HTTP parsing

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
    }

    private struct HTTPResponse {
        var status: Int
        var reason: String
        var headers: [String: String]
        var body: Data

        static let notFound = HTTPResponse(status: 404, reason: "Not Found",
                                           headers: ["Content-Type": "text/plain; charset=utf-8"],
                                           body: Data("Not Found".utf8))
    }

    nonisolated private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerString = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers)
    }

    // MARK: Routing

    nonisolated private func route(_ request: HTTPRequest, auth: HTTPAuthCredentials.Credentials?) -> HTTPResponse {
        if let auth, !verifyBasicAuth(headerValue: request.headers["authorization"], user: auth.user, password: auth.password) {
            return unauthorizedResponse(realm: auth.realm)
        }
        let path = pathWithoutQuery(request.path)
        if path == "/status.json" {
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "application/json"],
                                body: Data(#"{"status":"ok"}"#.utf8))
        }
        let relative: String
        if path == "/" {
            relative = "index.html"
        } else {
            relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        if relative.hasSuffix(".html"),
           let dynamic = renderDynamicHTML(relativePath: relative) {
            return dynamic
        }
        return staticFile(at: relative) ?? .notFound
    }

    // MARK: HTTP Basic auth

    nonisolated private func verifyBasicAuth(headerValue: String?, user: String, password: String) -> Bool {
        guard let headerValue else { return false }
        let prefix = "Basic "
        guard headerValue.hasPrefix(prefix) else { return false }
        let token = String(headerValue.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard let decoded = Data(base64Encoded: token),
              let decodedString = String(data: decoded, encoding: .utf8),
              let colon = decodedString.firstIndex(of: ":") else {
            return false
        }
        let suppliedUser = String(decodedString[..<colon])
        let suppliedPassword = String(decodedString[decodedString.index(after: colon)...])
        let userOK = constantTimeEqual(Array(suppliedUser.utf8), Array(user.utf8))
        let passwordOK = constantTimeEqual(Array(suppliedPassword.utf8), Array(password.utf8))
        return userOK && passwordOK
    }

    nonisolated private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    nonisolated private func sanitizedRealm(_ realm: String) -> String {
        var out = ""
        out.reserveCapacity(realm.count)
        for scalar in realm.unicodeScalars {
            switch scalar {
            case "\"", "\\", "\r", "\n":
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out.isEmpty ? HTTPAuthCredentials.defaultRealm : out
    }

    nonisolated private func unauthorizedResponse(realm: String) -> HTTPResponse {
        let safeRealm = sanitizedRealm(realm)
        return HTTPResponse(
            status: 401,
            reason: "Unauthorized",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "WWW-Authenticate": "Basic realm=\"\(safeRealm)\", charset=\"UTF-8\""
            ],
            body: Data("Authentication required".utf8)
        )
    }

    nonisolated private func pathWithoutQuery(_ path: String) -> String {
        if let q = path.firstIndex(of: "?") { return String(path[..<q]) }
        return path
    }

    // MARK: Dynamic HTML

    nonisolated private func renderDynamicHTML(relativePath: String) -> HTTPResponse? {
        guard !relativePath.isEmpty,
              let webRoot = Bundle.main.url(forResource: "Web", withExtension: nil) else {
            return nil
        }
        let fileURL = webRoot.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = webRoot.standardizedFileURL.path
        guard fileURL.path.hasPrefix(rootPath),
              var html = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        for (key, value) in replacements(forRelativePath: relativePath) {
            html = html.replacingOccurrences(of: "%%\(key)%%", with: value)
        }
        return HTTPResponse(status: 200, reason: "OK",
                            headers: ["Content-Type": "text/html; charset=utf-8"],
                            body: Data(html.utf8))
    }

    nonisolated private func replacements(forRelativePath relativePath: String) -> [String: String] {
        var dict = globalReplacements()
        switch relativePath {
        case "index2.html":
            dict["FAVORITES_ICON"]  = loadSVG(named: "favorites")
            dict["CATEGORIES_ICON"] = loadSVG(named: "categories")
            dict["TUNER_ICON"]      = loadSVG(named: "tuner")
            dict["DEVICE_ICON"]     = loadSVG(named: "devices")
            dict["GEAR_ICON"]       = loadSVG(named: "gear")
            dict["INFO_ICON"]       = loadSVG(named: "info")
        default:
            break
        }
        return dict
    }

    // Tokens shared across every dynamic page. Extend as pages migrate from
    // LocalRadio (e.g. NAV_BAR, COMPUTER_NAME, device-health messages).
    nonisolated private func globalReplacements() -> [String: String] {
        ["ERROR_MESSAGE": ""]
    }

    nonisolated private func loadSVG(named name: String) -> String {
        guard let webRoot = Bundle.main.url(forResource: "Web", withExtension: nil) else {
            return ""
        }
        let url = webRoot
            .appendingPathComponent("images")
            .appendingPathComponent("\(name).svg")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return stripXMLDeclaration(raw)
    }

    nonisolated private func stripXMLDeclaration(_ svg: String) -> String {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<?xml"),
              let end = trimmed.range(of: "?>") else {
            return trimmed
        }
        return String(trimmed[end.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Static file serving

    nonisolated private func staticFile(at relativePath: String) -> HTTPResponse? {
        guard !relativePath.isEmpty,
              let webRoot = Bundle.main.url(forResource: "Web", withExtension: nil) else {
            return nil
        }
        let fileURL = webRoot.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = webRoot.standardizedFileURL.path
        guard fileURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let contentType = mimeType(forExtension: fileURL.pathExtension.lowercased())
        return HTTPResponse(status: 200, reason: "OK",
                            headers: ["Content-Type": contentType],
                            body: data)
    }

    nonisolated private func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "eot": return "application/vnd.ms-fontobject"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
