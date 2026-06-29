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

    /// App services the web routes drive. Set by the owner (ContentView) before
    /// `start()`. Both are `@MainActor`; the nonisolated routing path reaches
    /// them by awaiting a MainActor hop (see `appStateResponse`).
    var sdrController: SDRController?
    var sqlite: SQLiteController?

    /// Stream configuration needed to render the `%%AUDIO_PLAYER%%` token. Points
    /// at the continuously-running LiveAudioServer, which serves the audio the web
    /// UI plays. A value type captured at `start()`; read from the nonisolated
    /// routing queue, so it is set before listeners begin and treated as immutable.
    struct WebConfig: Sendable {
        var streamHTTPPort: Int = 8080
        var streamHTTPSPort: Int? = nil
        /// LiveAudioServer AAC (ADTS in MPEG-4) mount; Safari-friendly.
        var aacMount: String = "/stream.m4a"
        var aacBitrate: Int = 128_000
        var autoplay: Bool = false
    }

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "com.dsward.AntennaHead.HTTPServer", qos: .userInitiated)

    func start(tlsIdentity: sec_identity_t? = nil,
               auth: HTTPAuthCredentials.Credentials? = nil,
               webConfig: WebConfig) {
        stop()
        do {
            httpListener = try makeListener(port: httpPort, tlsIdentity: nil, auth: auth, webConfig: webConfig)
            httpListener?.start(queue: queue)
            if let tlsIdentity {
                httpsListener = try makeListener(port: httpsPort, tlsIdentity: tlsIdentity, auth: auth, webConfig: webConfig)
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

    private func makeListener(port: UInt16, tlsIdentity: sec_identity_t?, auth: HTTPAuthCredentials.Credentials?, webConfig: WebConfig) throws -> NWListener {
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
        let isSecure = tlsIdentity != nil
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, auth: auth, isSecure: isSecure, webConfig: webConfig)
        }
        return listener
    }

    nonisolated private func handle(_ connection: NWConnection, auth: HTTPAuthCredentials.Credentials?, isSecure: Bool, webConfig: WebConfig) {
        connection.start(queue: queue)
        receive(on: connection, accumulator: Data(), auth: auth, isSecure: isSecure, webConfig: webConfig)
    }

    nonisolated private func receive(on connection: NWConnection, accumulator: Data, auth: HTTPAuthCredentials.Credentials?, isSecure: Bool, webConfig: WebConfig) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulator
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let request = self.parseRequest(buffer) {
                Task {
                    let response = await self.respond(request, auth: auth, isSecure: isSecure, webConfig: webConfig)
                    self.send(response, on: connection)
                }
                return
            }

            if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel()
                return
            }

            self.receive(on: connection, accumulator: buffer, auth: auth, isSecure: isSecure, webConfig: webConfig)
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
        var body: Data
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

        // Body (POST): wait until Content-Length bytes have arrived.
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        var body = Data()
        if contentLength > 0 {
            let bodyData = data[headerEnd.upperBound...]
            if bodyData.count < contentLength { return nil } // need more bytes
            body = Data(bodyData.prefix(contentLength))
        }
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
    }

    // MARK: Routing

    nonisolated private func respond(_ request: HTTPRequest, auth: HTTPAuthCredentials.Credentials?, isSecure: Bool, webConfig: WebConfig) async -> HTTPResponse {
        if let auth, !verifyBasicAuth(headerValue: request.headers["authorization"], user: auth.user, password: auth.password) {
            return unauthorizedResponse(realm: auth.realm)
        }
        let path = pathWithoutQuery(request.path)
        let host = hostname(from: request.headers["host"])
        if path == "/status.json" {
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "application/json"],
                                body: Data(#"{"status":"ok"}"#.utf8))
        }
        // Pages that read the DB or drive SDRController run on the MainActor.
        if let appResponse = await appStateResponse(path: path, request: request, host: host, isSecure: isSecure, webConfig: webConfig) {
            return appResponse
        }
        return staticOrDynamic(path: path, host: host, isSecure: isSecure, webConfig: webConfig)
    }

    /// Static asset or non-app dynamic page (index.html nav/audio, index2 icons).
    /// Runs on the routing queue so large assets don't block the MainActor.
    nonisolated private func staticOrDynamic(path: String, host: String, isSecure: Bool, webConfig: WebConfig) -> HTTPResponse {
        let relative: String
        if path == "/" {
            relative = "index.html"
        } else {
            relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        if relative.hasSuffix(".html"),
           let dynamic = renderHTML(relativePath: relative, host: host, isSecure: isSecure, webConfig: webConfig, extra: [:]) {
            return dynamic
        }
        return staticFile(at: relative) ?? .notFound
    }

    // MARK: App-state pages (favorites + Listen) — ported from HTTPWebServerConnection

    /// Handles the pages that need `sqlite`/`sdrController`. Returns nil for paths
    /// that aren't app-state, so the caller falls back to static/dynamic serving.
    @MainActor private func appStateResponse(path: String, request: HTTPRequest, host: String, isSecure: Bool, webConfig: WebConfig) -> HTTPResponse? {
        switch path {
        case "/favorites.html":
            return renderHTML(relativePath: "favorites.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["FAVORITES_TABLE": favoritesTableHTML()])

        case "/viewfavorite.html":
            var name = ""
            var item = "Error: missing favorite id"
            if let idString = queryValue("id", in: request.path), let id = Int64(idString) {
                (name, item) = viewFavorite(id: id)
            }
            return renderHTML(relativePath: "viewfavorite.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["VIEW_FAVORITE_NAME": htmlText(name), "VIEW_FAVORITE_ITEM": item])

        case "/listenbuttonclicked.html":
            // POST body is a serialized form: [{"name":"id","value":"N"}, ...]
            if let id = frequencyID(fromListenBody: request.body), id > 0 {
                try? sdrController?.startTasksForFrequency(id: id)
            }
            // The bundled template uses FREQUENCY_LISTEN_BUTTON_CLICKED_RESULT;
            // LISTEN_BUTTON_CLICKED_RESULT is included for parity with LocalRadio.
            return renderHTML(relativePath: "listenbuttonclicked.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["FREQUENCY_LISTEN_BUTTON_CLICKED_RESULT": "OK",
                                      "LISTEN_BUTTON_CLICKED_RESULT": "OK"])

        default:
            return nil
        }
    }

    /// `%%FAVORITES_TABLE%%` — ported from `generateFavoritesString`.
    @MainActor private func favoritesTableHTML() -> String {
        let frequencies = (try? sqlite?.allFrequencyRecords()) ?? []
        var s = "<table class='u-full-width'><thead><tr><th>Frequency</th><th>Name</th></tr></thead><tbody>"
        for f in frequencies {
            guard let id = f.id else { continue }
            let title = "Show \(f.stationName) at \(f.formattedFrequency)"
            s += "<tr><td>"
            s += "<a class='button button-primary two columns' type='submit' onclick=\"loadContent('viewfavorite.html?id=\(id)');\" title='\(htmlAttribute(title))'>\(htmlText(f.formattedFrequency))</a>"
            s += "</td><td>\(htmlText(f.stationName))</td></tr>"
        }
        s += "</tbody></table>"
        return s
    }

    /// `%%VIEW_FAVORITE_NAME%%` + `%%VIEW_FAVORITE_ITEM%%` — ported from
    /// `generateViewFavoriteItemStringForID`. Returns (station name, item HTML).
    @MainActor private func viewFavorite(id: Int64) -> (name: String, item: String) {
        guard let f = (try? sqlite?.frequencyRecord(forID: id)) ?? nil else {
            return ("", "Error getting favorite id = \(id)")
        }
        var modulation = f.modulation
        if modulation == "fm" && f.stereoFlag { modulation = "fm stereo" }
        var s = "<form id='listenForm' action='#'>"
        s += "<input type='hidden' name='id' value='\(id)'>"
        s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"var listenForm=getElementById('listenForm'); listenButtonClicked(listenForm);\" "
        s += "title='Click Listen to tune the RTL-SDR radio to this frequency.'>"
        s += "</form>"
        s += "<br><br>frequency: \(htmlText(f.formattedFrequency))<br>modulation: \(htmlText(modulation))<br>sample rate: \(f.sampleRate)<br><br>"
        return (f.stationName, s)
    }

    /// Extracts the `id` field from the Listen form's JSON body.
    nonisolated private func frequencyID(fromListenBody body: Data) -> Int64? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let array = object as? [[String: Any]] else { return nil }
        for field in array where (field["name"] as? String) == "id" {
            if let value = field["value"] as? String { return Int64(value) }
        }
        return nil
    }

    nonisolated private func queryValue(_ name: String, in path: String) -> String? {
        guard let q = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: q)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.first.map(String.init) == name else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    // Minimal HTML escaping for interpolated DB values.
    nonisolated private func htmlText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated private func htmlAttribute(_ s: String) -> String {
        htmlText(s).replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The hostname portion of a `Host` header, dropping any `:port`. Used to
    /// build absolute stream URLs that resolve from the same client (e.g. an
    /// iPhone reaching the Mac over the LAN), just on LiveAudioServer's port.
    nonisolated private func hostname(from hostHeader: String?) -> String {
        guard let hostHeader, !hostHeader.isEmpty else { return "localhost" }
        // IPv6 literal: [::1]:8090 → ::1
        if hostHeader.hasPrefix("[") {
            if let close = hostHeader.firstIndex(of: "]") {
                return String(hostHeader[hostHeader.index(after: hostHeader.startIndex)..<close])
            }
            return hostHeader
        }
        if let colon = hostHeader.firstIndex(of: ":") {
            return String(hostHeader[..<colon])
        }
        return hostHeader
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

    nonisolated private func renderHTML(relativePath: String, host: String, isSecure: Bool, webConfig: WebConfig, extra: [String: String]) -> HTTPResponse? {
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
        var dict = replacements(forRelativePath: relativePath, host: host, isSecure: isSecure, webConfig: webConfig)
        dict.merge(extra) { _, new in new }   // caller-supplied (DB-backed) tokens win
        for (key, value) in dict {
            html = html.replacingOccurrences(of: "%%\(key)%%", with: value)
        }
        return HTTPResponse(status: 200, reason: "OK",
                            headers: ["Content-Type": "text/html; charset=utf-8"],
                            body: Data(html.utf8))
    }

    nonisolated private func replacements(forRelativePath relativePath: String, host: String, isSecure: Bool, webConfig: WebConfig) -> [String: String] {
        var dict = globalReplacements()
        switch relativePath {
        case "index.html":
            dict["NAV_BAR"]      = navBarHTML()
            dict["AUDIO_PLAYER"] = audioPlayerHTML(host: host, isSecure: isSecure, webConfig: webConfig)
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

    // MARK: %%NAV_BAR%% and %%AUDIO_PLAYER%% (ported from LocalRadio's HTTPWebServerConnection)

    /// Static top navigation bar (Back / Top / Now Playing). The referenced JS
    /// functions live in `index.html`.
    nonisolated private func navBarHTML() -> String {
        """
           <div class="navbar-spacer"></div>
           <nav class="navbar">
              <div class="container">
                <ul class="navbar-list">
                  <li class="navbar-item"><a class="navbar-link" href="#" onclick="backButtonClicked(self);" title="Click the Back button to return to the previous page in the web interface">Back</a></li>
                  <li class="navbar-item"><a class="navbar-link" href="#" onclick="loadContent('index2.html');" title="Click the Top button to reload the web interface.">Top</a></li>
                  <li class="navbar-item"><a class="navbar-link" id="nowPlayingNavBarLink" href="#" onclick="loadContent('nowplaying.html');" title="Click the Now Playing button to see the current activity on the radio, including the live Signal Level.">Now Playing</a></li>
                </ul>
              </div>
            </nav>
        """
    }

    /// `<audio>` element pointing at the LiveAudioServer AAC stream. Uses the
    /// same hostname the client used to reach this page, on LiveAudioServer's
    /// HTTP(S) port, so it resolves from phones on the LAN.
    nonisolated private func audioPlayerHTML(host: String, isSecure: Bool, webConfig: WebConfig) -> String {
        let scheme = isSecure ? "https" : "http"
        let port = isSecure ? (webConfig.streamHTTPSPort ?? webConfig.streamHTTPPort) : webConfig.streamHTTPPort
        let src = "\(scheme)://\(host):\(port)\(webConfig.aacMount)"
        // HE-AAC (low bitrate) advertises as audio/aacp; AAC-LC as audio/aac.
        let format = webConfig.aacBitrate < 64_000 ? "aacp" : "aac"
        let autoplay = webConfig.autoplay ? "autoplay " : ""
        let handlers =
            " onabort='audioPlayerAbort(this);' oncanplay='audioPlayerCanPlay(this);'"
            + " oncanplaythrough='audioPlayerCanPlaythrough(this);' ondurationchange='audioPlayerDurationChange(this);'"
            + " onemptied='audioPlayerEmptied(this);' onended='audioPlayerEnded(this);'"
            + " onerror='audioPlayerError(this, event);' onloadeddata='audioPlayerLoadedData(this);'"
            + " onloadedmetadata='audioPlayerLoadedMetadata(this);' onloadstart='audioPlayerLoadStart(this);'"
            + " onpause='audioPlayerPaused(this);' onplay='audioPlayerPlay(this);'"
            + " onplaying='audioPlayerPlaying(this);' onprogress='audioPlayerProgress(this);'"
            + " onratechange='audioPlayerRateChange(this);' onseeked='audioPlayerSeeked(this);'"
            + " onseeking='audioPlayerSeeking(this);' onstalled='audioPlayerStalled(this);'"
            + " onsuspend='audioPlayerSuspend(this);' ontimeupdate='audioPlayerTimeUpdate(this);'"
            + " onwaiting='audioPlayerWaiting(this);'"
        return "<audio id='audio_element' controls \(autoplay)preload=\"none\" src='\(src)' type='audio/\(format)'\(handlers)>Your browser does not support the audio element.</audio>"
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
