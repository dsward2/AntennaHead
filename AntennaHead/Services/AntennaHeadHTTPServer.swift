import AppKit
import AntennaHeadAPI
import AVFoundation
import CoreMedia
import Foundation
import Network
import PipelineRunner
import SharedLogging

private extension Dictionary where Key == String, Value == Any {
    /// String value for a key, coercing JSON numbers to their string form.
    func string(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }
}

@MainActor
@Observable
final class AntennaHeadHTTPServer {
    /// Listener ports. Set by the owner (from `PortSettings`) before `start()`.
    var httpPort: UInt16 = 8090
    var httpsPort: UInt16 = 8094
    private(set) var isRunning = false
    private(set) var httpsEnabled = false
    /// Set when a listener's bind actually fails (e.g. port still held by the
    /// previous instance) — NWListener reports this asynchronously via its
    /// stateUpdateHandler, so without this `isRunning` would otherwise claim
    /// success even when nothing is actually listening.
    private(set) var lastError: Error?

    /// Retained for compatibility with code that reads `httpServer.port`.
    var port: UInt16 { httpPort }

    /// Posted after the web Settings page stores a new value. ContentView
    /// observes this and restarts services so the change takes effect (the
    /// output bitrate is baked into both `WebConfig` and the LAS launch args).
    static let settingsDidChangeNotification = Notification.Name("AntennaHeadHTTPServer.settingsDidChange")

    /// Posted after the web Settings page stores a new colour scheme. The
    /// embedded `WebRadioView`s observe this to re-sync their WKWebView's
    /// `appearance` (native form controls, the `<audio>` transport, scroll
    /// bars) with a forced Light/Dark choice — no service restart, and the
    /// page CSS has already reacted to the live `data-theme` change.
    static let webUIThemeDidChangeNotification = Notification.Name("AntennaHeadHTTPServer.webUIThemeDidChange")

    /// `app_config` key holding the system-wide stream output bitrate
    /// in bits/sec (key name retained from LocalRadio's database).
    static let outputBitrateConfigKey = "AACBitrate"
    static let defaultOutputBitrate = 128_000
    static let outputBitrateOptions = [32_000, 48_000, 64_000, 96_000, 128_000, 192_000, 256_000]

    /// `app_config` key for the web UI colour scheme: `"auto"` (follow the
    /// viewer's OS setting), `"light"`, or `"dark"`. Baked into `index.html`
    /// as a `data-theme` attribute on `<html>` (see `renderHTML` and
    /// `css/custom.css`). Unlike `AACBitrate` this is purely cosmetic and
    /// needs no service restart — only a page reload — so the web Settings
    /// page updates it through its own lightweight `/applywebuitheme.html`
    /// route rather than the "save and restart" AAC form.
    static let webUIThemeConfigKey = "AntennaHeadWebUITheme"
    static let webUIThemeOptions = ["auto", "light", "dark"]
    static let defaultWebUITheme = "auto"

    /// App-settings keys for the "Text to Speech" folder chosen on the Audio
    /// Devices page. The bookmark is security-scoped (created from an
    /// NSOpenPanel selection, same pattern as ConfigurationView's ControlBooth
    /// picker); the plain path is kept alongside it for display and as a
    /// fallback. Both persist in the app-settings table across launches.
    static let textToSpeechFolderBookmarkKey = "AntennaHeadTextToSpeechFolderBookmark"
    static let textToSpeechFolderPathKey = "AntennaHeadTextToSpeechFolderPath"
    /// Guard rails when reading the folder — a spoken sequence far larger than
    /// this is almost certainly a mistaken folder choice.
    private static let textToSpeechMaxFiles = 500
    private static let textToSpeechMaxTotalCharacters = 1_000_000

    /// The stored output bitrate (bits/sec), falling back to the default.
    @MainActor static func storedOutputBitrate(sqlite: SQLiteController?) -> Int {
        let stored = ((try? sqlite?.appSettingsValue(forKey: outputBitrateConfigKey)) ?? nil)
            .flatMap(Int.init)
        guard let stored, outputBitrateOptions.contains(stored) else { return defaultOutputBitrate }
        return stored
    }

    /// The stored web UI colour scheme, falling back to `defaultWebUITheme`
    /// for a missing or unrecognised value.
    @MainActor static func storedWebUITheme(sqlite: SQLiteController?) -> String {
        let stored = (try? sqlite?.appSettingsValue(forKey: webUIThemeConfigKey)) ?? nil
        guard let stored, webUIThemeOptions.contains(stored) else { return defaultWebUITheme }
        return stored
    }

    /// App services the web routes drive. Set by the owner (ContentView) before
    /// `start()`. Both are `@MainActor`; the nonisolated routing path reaches
    /// them by awaiting a MainActor hop (see `appStateResponse`).
    var sdrController: SDRController?
    var sqlite: SQLiteController?
    /// Drives the `%%AUDIO_PLAYER%%` bar's AAC recorder toggle (`/api/aac-recorder/*`).
    var liveAudioServerProcessManager: LiveAudioServerProcessManager?

    /// Stream configuration needed to render the `%%AUDIO_PLAYER%%` token. The
    /// audio the web UI plays is ultimately served by the continuously-running
    /// LiveAudioServer, but the `<audio>` element itself is pointed at this
    /// server (`selfHTTPPort`/`selfHTTPSPort`), which proxies the HLS request
    /// through to LAS (`proxyToLiveAudioServer`) rather than exposing LAS's
    /// separate port directly — see that field's doc comment for why. A value
    /// type captured at `start()`; read from the nonisolated routing queue, so
    /// it is set before listeners begin and treated as immutable.
    struct WebConfig: Sendable {
        var streamHTTPPort: Int = 8080
        var streamHTTPSPort: Int? = nil
        /// LiveAudioServer AAC (ADTS in MPEG-4) mount; Safari-friendly.
        var aacMount: String = "/stream.m4a"
        /// LiveAudioServer's live HLS playlist mount — segmented, so it has
        /// real per-segment Content-Length framing unlike the raw ADTS
        /// stream. AirPlay 2 receivers that fetch the audio URL directly
        /// (e.g. Apple TV) appear to need this rather than an open-ended
        /// live byte stream.
        var hlsMount: String = "/hls/index.m3u8"
        /// Prefix LiveAudioServer's HLS segment filenames share (see
        /// `HLSSegmenter.segmentURI` in LiveAudioServerCore) — segment URIs in
        /// the playlist are root-relative (e.g. `/hls/seg-123.aac`), so once
        /// the playlist itself is fetched from this server (see
        /// `proxyToLiveAudioServer`), the browser resolves segment requests
        /// against this same origin automatically; this prefix is how
        /// `respond(_:auth:isSecure:webConfig:)` recognizes them as also
        /// needing proxying to LAS.
        var hlsSegmentPrefix: String = "/hls/seg-"
        var aacBitrate: Int = 128_000
        var autoplay: Bool = false
        var controlBoothEnabled: Bool = false
        /// AntennaHead's own web-server port(s). The `<audio>` element's HLS
        /// request is pointed at *this* server (proxied through to LAS
        /// internally) rather than LAS's separate port, so a browser
        /// authenticates once: per RFC 7617 the Basic Auth "protection space"
        /// includes the port, so even a matching realm on a different port
        /// would otherwise force a second login when the audio element loads.
        var selfHTTPPort: Int = 8090
        var selfHTTPSPort: Int? = nil
    }

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "com.dsward.AntennaHead.HTTPServer", qos: .userInitiated)

    /// Params from the most recent `start()`, kept so a bind retry can rebuild
    /// just the failed listener without disturbing the other one.
    private var lastTLSIdentity: sec_identity_t?
    private var lastAuth: HTTPAuthCredentials.Credentials?
    private var lastWebConfig: WebConfig?

    /// A previous instance's listener socket can still be draining when a new
    /// instance starts (or a settings-triggered restart races the old
    /// listener's teardown), so the first bind attempt can transiently fail
    /// with `EADDRINUSE`. Retry a few times with backoff before giving up.
    private static let maxBindRetries = 5
    private static let bindRetryBaseDelay = 0.3
    private var httpRetryAttempt = 0
    private var httpsRetryAttempt = 0

    func start(tlsIdentity: sec_identity_t? = nil,
               auth: HTTPAuthCredentials.Credentials? = nil,
               webConfig: WebConfig) {
        stop()
        lastError = nil
        httpRetryAttempt = 0
        httpsRetryAttempt = 0
        lastTLSIdentity = tlsIdentity
        lastAuth = auth
        lastWebConfig = webConfig
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
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", "failed to start: \(error)")
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
        // Advertise the web UI on the LAN via Bonjour (visible in Safari's
        // Bonjour bookmarks and discovery apps).
        listener.service = NWListener.Service(name: "AntennaHead",
                                              type: isSecure ? "_https._tcp" : "_http._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, auth: auth, isSecure: isSecure, webConfig: webConfig)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state, isSecure: isSecure)
            }
        }
        return listener
    }

    /// Surfaces a bind failure (e.g. `POSIXErrorCode.EADDRINUSE` from the
    /// previous listener not having released the port yet) instead of leaving
    /// `isRunning` claiming success while nothing is actually listening.
    /// `EADDRINUSE` specifically is retried with backoff (see `scheduleRetry`)
    /// since it's usually transient; other failures surface immediately.
    @MainActor private func handleListenerState(_ state: NWListener.State, isSecure: Bool) {
        switch state {
        case .ready:
            if isSecure {
                httpsRetryAttempt = 0
                httpsEnabled = true
            } else {
                httpRetryAttempt = 0
                isRunning = true
            }
            lastError = nil
        case .failed(let error):
            let attempt = isSecure ? httpsRetryAttempt : httpRetryAttempt
            if isEADDRINUSE(error), attempt < Self.maxBindRetries {
                LogStore.shared.log(.warning, source: "AntennaHeadHTTPServer",
                    "\(isSecure ? "HTTPS" : "HTTP") bind failed (\(error)); retrying (attempt \(attempt + 1)/\(Self.maxBindRetries))")
                scheduleRetry(isSecure: isSecure)
                return
            }
            lastError = error
            if isSecure {
                httpsEnabled = false
            } else {
                isRunning = false
            }
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer",
                "\(isSecure ? "HTTPS" : "HTTP") listener failed: \(error)")
        default:
            break
        }
    }

    private func isEADDRINUSE(_ error: Error) -> Bool {
        guard let nwError = error as? NWError, case .posix(let code) = nwError else { return false }
        return code == .EADDRINUSE
    }

    private func scheduleRetry(isSecure: Bool) {
        if isSecure {
            httpsRetryAttempt += 1
        } else {
            httpRetryAttempt += 1
        }
        let attempt = isSecure ? httpsRetryAttempt : httpRetryAttempt
        let delay = Self.bindRetryBaseDelay * Double(attempt)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.retryListener(isSecure: isSecure)
        }
    }

    /// Rebuilds and rebinds just the listener that failed, leaving the other
    /// one (if any) untouched.
    private func retryListener(isSecure: Bool) {
        guard let webConfig = lastWebConfig else { return }
        do {
            if isSecure {
                guard let tlsIdentity = lastTLSIdentity else { return }
                httpsListener?.cancel()
                httpsListener = try makeListener(port: httpsPort, tlsIdentity: tlsIdentity, auth: lastAuth, webConfig: webConfig)
                httpsListener?.start(queue: queue)
            } else {
                httpListener?.cancel()
                httpListener = try makeListener(port: httpPort, tlsIdentity: nil, auth: lastAuth, webConfig: webConfig)
                httpListener?.start(queue: queue)
            }
        } catch {
            lastError = error
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer",
                "\(isSecure ? "HTTPS" : "HTTP") retry bind failed: \(error)")
        }
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

        nonisolated static let notFound = HTTPResponse(status: 404, reason: "Not Found",
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
        if path == webConfig.hlsMount || path.hasPrefix(webConfig.hlsSegmentPrefix) {
            return await proxyToLiveAudioServer(path: path, auth: auth, webConfig: webConfig)
        }
        if path.hasPrefix(Self.recordingsDownloadPrefix) {
            return recordingDownloadResponse(path: path, request: request)
        }
        // Pages that read the DB or drive SDRController run on the MainActor.
        if let appResponse = await appStateResponse(path: path, request: request, host: host, isSecure: isSecure, webConfig: webConfig) {
            return appResponse
        }
        return staticOrDynamic(path: path, host: host, isSecure: isSecure, webConfig: webConfig)
    }

    /// Fetches an HLS playlist/segment from the co-located LiveAudioServer
    /// instance over loopback and relays it verbatim, so the browser only
    /// ever talks to this server's origin for the embedded audio player —
    /// see `WebConfig.selfHTTPPort`'s doc comment for why that's what makes a
    /// single Basic Auth login cover both servers. Only HLS (bounded,
    /// single-shot requests) is proxied this way; LAS's raw infinite mp3/m4a
    /// icy streams are not, since this server only supports fully-buffered
    /// single-shot responses (see `HTTPResponse`) and an infinite stream needs
    /// a genuine long-lived relay this server doesn't have — HLS's segmented
    /// design fits the existing request/response model without needing one.
    /// Always dials LAS over plain loopback HTTP regardless of `isSecure`;
    /// TLS only matters for the untrusted external hop this server itself
    /// terminates.
    nonisolated private func proxyToLiveAudioServer(path: String, auth: HTTPAuthCredentials.Credentials?,
                                                     webConfig: WebConfig) async -> HTTPResponse {
        guard let url = URL(string: "http://127.0.0.1:\(webConfig.streamHTTPPort)\(path)") else {
            return .notFound
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let auth, let b64 = "\(auth.user):\(auth.password)".data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .notFound }
            guard http.statusCode != 404 else { return .notFound }
            var headers: [String: String] = ["Cache-Control": "no-cache, no-store"]
            if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
                headers["Content-Type"] = contentType
            }
            return HTTPResponse(status: http.statusCode,
                                reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                                headers: headers, body: data)
        } catch {
            return HTTPResponse(status: 502, reason: "Bad Gateway",
                                headers: ["Content-Type": "text/plain; charset=utf-8"],
                                body: Data("LiveAudioServer unreachable: \(error.localizedDescription)".utf8))
        }
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
    @MainActor private func appStateResponse(path: String, request: HTTPRequest, host: String, isSecure: Bool, webConfig: WebConfig) async -> HTTPResponse? {
        switch path {
        case "/", "/index.html":
            // The shell page is rendered here (not on the nonisolated
            // static/dynamic path) so the stored colour scheme can be baked
            // in as `<html data-theme=…>` — every fragment is injected into
            // this page's `#content_frame`, so setting it once on the shell
            // themes the whole UI.
            return renderHTML(relativePath: "index.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["THEME": Self.storedWebUITheme(sqlite: sqlite)])

        case "/applywebuitheme.html":
            // POST body is `{theme: "auto"|"light"|"dark"}` from
            // applyWebUITheme() in js/antennahead.js. Cosmetic only: persist
            // it for subsequent renders, no notification / no restart.
            let theme = jsonObject(fromBody: request.body).string("theme")
            if Self.webUIThemeOptions.contains(theme) {
                try? sqlite?.storeAppSettingsValue(theme, forKey: Self.webUIThemeConfigKey)
                NotificationCenter.default.post(name: Self.webUIThemeDidChangeNotification, object: nil)
            }
            return okResponse()

        case "/favorites.html":
            return renderHTML(relativePath: "favorites.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["FAVORITES_TABLE": favoritesTableHTML()])

        case "/categories.html":
            return renderHTML(relativePath: "categories.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["CATEGORIES_TABLE": categoriesTableHTML()])

        case "/tuner_wbfm.html", "/tuner_general.html", "/tuner_am.html", "/tuner_aviation.html":
            // Tuner sub-category pages: fill the "add to category" pop-up.
            return renderHTML(relativePath: String(path.dropFirst()), host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["CATEGORY_SELECT": categorySelectOptionsHTML()])

        case "/tuner_advanced.html":
            return renderHTML(relativePath: "tuner_advanced.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["TUNER_FORM": newFrequencyFormHTML()])

        case "/recordings.html":
            return renderHTML(relativePath: "recordings.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["RECORDINGS_LIST": recordingsListHTML()])

        case "/recordingslistenbuttonclicked.html":
            let fields = formFields(fromBody: request.body)
            if let fileName = fields["selected_file"], !fileName.isEmpty {
                try? sdrController?.startTasksForRecording(fileName: fileName,
                                                            repeatAudio: fields["repeat_flag"] == "1")
            }
            return okResponse()

        // `devices.html` is now a plain hub of links (no DB-backed tokens), so
        // it falls through to static/dynamic serving. Each Listen mode lives on
        // its own sub-page below, carrying just its one form.
        case "/deviceaudioinput.html":
            return renderHTML(relativePath: "deviceaudioinput.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["DEVICES_FORM": devicesFormHTML()])

        case "/devicegqrx.html":
            return renderHTML(relativePath: "devicegqrx.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["GQRX_FORM": gqrxFormHTML()])

        case "/devicetexttospeech.html":
            return renderHTML(relativePath: "devicetexttospeech.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["TEXT_TO_SPEECH_FORM": textToSpeechFormHTML()])

        case "/devicelistenbuttonclicked.html":
            // Buttons are wired; the Core Audio device-input pipeline is deferred
            // (needs a capture helper), so this currently logs .notImplemented.
            let fields = formFields(fromBody: request.body)
            sdrController?.startTasksForDevice(deviceName: fields["audio_input"] ?? "",
                                               deviceAudioOutputFilter: fields["audio_output_filter"] ?? "vol 1")
            return okResponse()

        case "/gqrxlistenbuttonclicked.html":
            let gqrxChannels = Int(formFields(fromBody: request.body)["gqrx_channels"] ?? "2") ?? 2
            sdrController?.startGqrxListening(channels: gqrxChannels)
            return okResponse()

        case "/texttospeechchoosefolder.html":
            // Runs a native folder chooser on the host Mac and persists the
            // selection (security-scoped bookmark + path). Responds with the
            // currently-saved path so the web UI can update its label.
            let path = chooseTextToSpeechFolder()
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "text/plain; charset=utf-8"],
                                body: Data(path.utf8))

        case "/texttospeechlistenbuttonclicked.html":
            // Body is a JSON *object*: {sequence, repeat}. The folder itself is
            // the saved setting — resolve its bookmark and read the .txt files
            // here, then hand them to SDRController.
            let o = jsonObject(fromBody: request.body)
            let randomOrder = (o["sequence"] as? String) == "random"
            let repeatForever = (o["repeat"] as? String) == "1"
            sdrController?.startTextToSpeech(files: textToSpeechFolderFiles(),
                                            randomOrder: randomOrder, repeatForever: repeatForever)
            return okResponse()

        case "/settings.html":
            return renderHTML(relativePath: "settings.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["AAC_BITRATE_SELECT": outputBitrateSelectOptionsHTML(),
                                      "WEB_UI_THEME_SELECT": webUIThemeSelectOptionsHTML()])

        case "/applyaacsettings.html":
            // POST body is a JSON object {bitrate: "<bps>"} from applyAACSettings().
            let bitrate = Int(jsonObject(fromBody: request.body).string("bitrate"))
            if let bitrate, Self.outputBitrateOptions.contains(bitrate) {
                try? sqlite?.storeAppSettingsValue("\(bitrate)", forKey: Self.outputBitrateConfigKey)
                NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
            }
            return okResponse()

        case "/frequencylistenbuttonclicked.html":
            // Ad-hoc tune from the web Tuner. Body is a JSON *object*
            // {frequency, sample_rate, tuner_gain, stereo_flag, modulation, usb_device_string}.
            let o = jsonObject(fromBody: request.body)
            if let hz = Int(o.string("frequency")), hz > 0 {
                sdrController?.startTasksForFrequency(
                    frequencyHz: hz,
                    sampleRate: Int(o.string("sample_rate")) ?? 170_000,
                    tunerGain: Double(o.string("tuner_gain")) ?? 49.6,
                    stereo: o.string("stereo_flag") == "1",
                    modulation: o.string("modulation"),
                    usbDevice: o.string("usb_device_string"))
            }
            return okResponse()

        case "/rtlsdrdevices.html":
            // Populates the "USB Device" combo box's <datalist> (see
            // usbDeviceFieldHTML / antennahead.js's populateUSBDeviceDatalist).
            // RTLSDRDeviceList.enumerate() blocks briefly on libusb
            // enumeration, so it's run off the main actor even though this
            // switch itself executes on it.
            let devices = await Task.detached(priority: .utility) {
                RTLSDRDeviceList.enumerate()
            }.value
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "application/json"],
                                body: usbDeviceOptionsJSON(devices: devices))

        case "/insertnewfrequency.html":
            insertNewFrequency(fromBody: request.body)
            return okResponse()

        case "/category.html":
            guard let id = queryValue("id", in: request.path).flatMap(Int64.init),
                  let c = (try? sqlite?.categoryRecord(forID: id)) ?? nil else {
                return renderHTML(relativePath: "category.html", host: host, isSecure: isSecure, webConfig: webConfig,
                                  extra: ["CATEGORY_NAME": "Error: category not found",
                                          "SCAN_CATEGORY_BUTTON": "", "CATEGORY_TABLE": "",
                                          "EDIT_CATEGORY_LIST_BUTTON": "", "CATEGORY_SETTINGS_BUTTON": ""])
            }
            return renderHTML(relativePath: "category.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["CATEGORY_NAME": htmlText(c.categoryName),
                                      "SCAN_CATEGORY_BUTTON": scanCategoryButtonHTML(category: c),
                                      "CATEGORY_TABLE": categoryFavoritesTableHTML(categoryID: id),
                                      "EDIT_CATEGORY_LIST_BUTTON": categoryNavButtonHTML(page: "editcategory.html", id: id, label: "Edit Frequencies List"),
                                      "CATEGORY_SETTINGS_BUTTON": categoryNavButtonHTML(page: "editcategorysettings.html", id: id, label: "Category Settings")])

        case "/editcategory.html":
            guard let id = queryValue("id", in: request.path).flatMap(Int64.init),
                  let c = (try? sqlite?.categoryRecord(forID: id)) ?? nil else {
                return renderHTML(relativePath: "editcategory.html", host: host, isSecure: isSecure, webConfig: webConfig,
                                  extra: ["EDIT_CATEGORY_NAME": "Error: category not found",
                                          "EDIT_CATEGORY_TABLE": "", "DELETE_CATEGORY_BUTTON": ""])
            }
            return renderHTML(relativePath: "editcategory.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["EDIT_CATEGORY_NAME": htmlText(c.categoryName),
                                      "EDIT_CATEGORY_TABLE": editCategoryTableHTML(categoryID: id),
                                      "DELETE_CATEGORY_BUTTON": deleteCategoryButtonHTML(categoryID: id, name: c.categoryName)])

        case "/editcategorysettings.html":
            guard let id = queryValue("id", in: request.path).flatMap(Int64.init),
                  let c = (try? sqlite?.categoryRecord(forID: id)) ?? nil else {
                return renderHTML(relativePath: "editcategorysettings.html", host: host, isSecure: isSecure, webConfig: webConfig,
                                  extra: ["EDIT_CATEGORY_NAME": "Error: category not found", "EDIT_CATEGORY_SETTINGS": ""])
            }
            return renderHTML(relativePath: "editcategorysettings.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["EDIT_CATEGORY_NAME": htmlText(c.categoryName),
                                      "EDIT_CATEGORY_SETTINGS": editCategorySettingsFormHTML(category: c)])

        case "/editcategoryitem.html":
            // GET web service: toggle a frequency's membership in a category.
            if let catID = queryValue("cat_id", in: request.path).flatMap(Int64.init),
               let freqID = queryValue("freq_id", in: request.path).flatMap(Int64.init) {
                let isMember = queryValue("is_member", in: request.path) == "true"
                toggleCategoryItem(catID: catID, freqID: freqID, isMember: isMember)
            }
            return okResponse()

        case "/addcategory.html":
            addCategory(fromBody: request.body)
            return okResponse()

        case "/storecategory.html":
            saveCategory(fromBody: request.body)
            return okResponse()

        case "/deletecategory.html":
            deleteCategory(fromBody: request.body)
            return okResponse()

        case "/scannerlistenbuttonclicked.html":
            if let id = frequencyID(fromListenBody: request.body), id > 0 {
                try? sdrController?.startTasksForCategoryScan(id: id)
            }
            return okResponse()

        case "/viewfavorite.html":
            var name = ""
            var item = "Error: missing favorite id"
            if let idString = queryValue("id", in: request.path), let id = Int64(idString) {
                (name, item) = viewFavorite(id: id)
            }
            return renderHTML(relativePath: "viewfavorite.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["VIEW_FAVORITE_NAME": htmlText(name), "VIEW_FAVORITE_ITEM": item])

        case "/editfavorite.html":
            var name = ""
            var item = "Error: missing favorite id"
            if let idString = queryValue("id", in: request.path), let id = Int64(idString) {
                (name, item) = editFavorite(id: id)
            }
            return renderHTML(relativePath: "editfavorite.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["EDIT_FAVORITE_NAME": htmlText(name), "EDIT_FAVORITE": item])

        case "/storefrequency.html":
            saveFrequency(fromBody: request.body)
            return okResponse()

        case "/deletefrequency.html":
            deleteFrequency(fromBody: request.body)
            return okResponse()

        case "/nowplaying.html":
            let page = nowPlayingPage()
            return renderHTML(relativePath: "nowplaying.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["NOW_PLAYING_NAME": htmlText(page.name),
                                      "NOW_PLAYING_DETAILS": page.details,
                                      "OPEN_AUDIO_PLAYER_PAGE_BUTTON": Self.openAudioPlayerButtonHTML])

        case "/nowplayingstatus.html":
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "application/json"],
                                body: nowPlayingStatusJSON())

        case "/captions.html":
            return renderHTML(relativePath: "captions.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: [:])

        case "/captions.json":
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "application/json",
                                          "Cache-Control": "no-cache, no-store"],
                                body: captionsJSON())

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

        case "/controlbooth.html":
            return htmlFragmentResponse(controlBoothPageHTML())

        case "/controlboothlistenbuttonclicked.html":
            if let name = formFields(fromBody: request.body)["pipeline_select"], !name.isEmpty {
                // Stop whatever ControlBooth pipeline is already running before
                // switching — otherwise the old and new pipelines' audio overlap
                // until the user separately clicks Stop. stopAllPipelines() waits
                // for ControlBooth's reply, so the old pipeline has actually
                // stopped before we start AntennaHead's receiver below.
                try? ControlBoothClient.stopAllPipelines()
                // Start AntennaHead's receiver first so PCMUDPReceiver is bound
                // on port 6019 before ControlBooth's PCMUDPSender begins sending.
                // startControlBoothListening now actually waits for that binding
                // to happen (rather than just for the launch to be scheduled)
                // before returning, closing a race that used to intermittently
                // collapse the ControlBooth pipeline with a "Connection refused"
                // on its very first UDP send.
                await sdrController?.startControlBoothListening(name: name)
                try? ControlBoothClient.startPipeline(named: name)
            }
            return okResponse()

        case "/controlboothstop.html":
            try? ControlBoothClient.stopAllPipelines()
            sdrController?.terminateTasks()
            return htmlFragmentResponse(controlBoothPageHTML())

        case "/controlboothlaunched.html":
            launchControlBooth()
            return htmlFragmentResponse(controlBoothPageHTML())

        case "/api/aac-recorder/status":
            return aacRecorderStatusResponse()

        case "/api/aac-recorder/start":
            return await startAACRecording()

        case "/api/aac-recorder/stop":
            if let mgr = liveAudioServerProcessManager {
                await mgr.stopRecording()
            }
            return aacRecorderStatusResponse()

        // MARK: JSON API v1 (AntennaHeadAPI) — see that package's README for
        // why these are separate types from the *.html fragment routes'
        // dictionaries above, not just this switch's JSON-shaped siblings.
        case APIEndpoint.categories:
            return apiCategoriesResponse()

        case APIEndpoint.favorites:
            return apiFavoritesResponse()

        case APIEndpoint.nowPlaying:
            return apiNowPlayingResponse()

        case APIEndpoint.tune:
            return apiTuneResponse(body: request.body)

        case APIEndpoint.startScan:
            return apiStartScanResponse(body: request.body)

        case APIEndpoint.stop:
            return apiStopResponse()

        case APIEndpoint.recorderStatus:
            return apiRecorderStatusResponse()

        case APIEndpoint.devices:
            return apiDevicesResponse()

        case APIEndpoint.startDevice:
            return apiStartDeviceResponse(body: request.body)

        case APIEndpoint.recordings:
            return apiRecordingsResponse()

        case APIEndpoint.controlBoothStatus:
            return apiControlBoothStatusResponse()

        case APIEndpoint.controlBoothLaunch:
            return apiControlBoothLaunchResponse()

        case APIEndpoint.controlBoothStart:
            return await apiControlBoothStartResponse(body: request.body)

        case APIEndpoint.controlBoothStop:
            return apiControlBoothStopResponse()

        default:
            return nil
        }
    }

    // MARK: AAC recorder toggle (`%%AUDIO_PLAYER%%` bar)

    /// Starts a recording of the live AAC stream to a timestamped file in the
    /// shared App Group Recordings folder — the same destination ControlBooth
    /// and the LiveAudioServer status tab's recorder bridge use (see
    /// `SharedRecordingFolder`). There's no path field in this compact toggle
    /// (unlike LAS's own status page), so the filename is always generated
    /// here rather than supplied by the caller.
    @MainActor private func startAACRecording() async -> HTTPResponse {
        guard let mgr = liveAudioServerProcessManager else {
            return jsonErrorResponse("LiveAudioServer is not available.", status: 503)
        }
        guard let folderURL = SharedRecordingFolder.url else {
            return jsonErrorResponse("AntennaHead's shared recording folder isn't available — check its App Group entitlement.", status: 500)
        }
        if !mgr.isRecording {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            df.locale = Locale(identifier: "en_US_POSIX")
            let filename = "AntennaHead-\(df.string(from: Date())).aac"
            await mgr.startRecording(at: folderURL.appendingPathComponent(filename))
        }
        return aacRecorderStatusResponse()
    }

    @MainActor private func aacRecorderStatusResponse() -> HTTPResponse {
        var dict: [String: Any] = ["recording": liveAudioServerProcessManager?.isRecording ?? false]
        if let startedAt = liveAudioServerProcessManager?.recordingStartedAt {
            dict["startedAt"] = ISO8601DateFormatter().string(from: startedAt)
        }
        let body = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, reason: "OK",
                            headers: ["Content-Type": "application/json", "Cache-Control": "no-cache, no-store"],
                            body: body)
    }

    @MainActor private func jsonErrorResponse(_ message: String, status: Int) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            reason: HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
                            headers: ["Content-Type": "application/json"],
                            body: body)
    }

    // MARK: JSON API v1 (AntennaHeadAPI)
    //
    // Additive routes for non-WebKit clients (tvOS, watchOS — see the
    // AntennaHeadAPI package). Deliberately built from purpose-built summary
    // types, not by reusing the *.html routes' dictionary-of-`Any` approach
    // above: see FrequencySummary's/CategorySummary's doc comments for why
    // the full GRDB records aren't what gets served here. Every handler below
    // stays a thin translation from AntennaHead's existing model/database
    // calls into `AntennaHeadAPI` types — no new business logic, matching the
    // feasibility study's premise that the tuning/scanning logic itself
    // doesn't need reimplementing for these clients, only exposing.

    /// Encodes any `AntennaHeadAPI` response type as the JSON body. `.iso8601`
    /// matches `AACRecorderStatus.startedAt`'s expectations and is a
    /// reasonable default for any future `Date` field this API adds.
    @MainActor private func apiEncode<T: Encodable>(_ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            return jsonErrorResponse("encoding failure", status: 500)
        }
        return HTTPResponse(status: 200, reason: "OK",
                            headers: ["Content-Type": "application/json", "Cache-Control": "no-cache, no-store"],
                            body: body)
    }

    @MainActor private func apiCategoriesResponse() -> HTTPResponse {
        let categories = (try? sqlite?.allCategoryRecords()) ?? []
        let summaries = categories.compactMap { category -> CategorySummary? in
            guard let id = category.id else { return nil }
            // No dedicated count query — matches the cost of the equivalent
            // *.html rendering path, which walks the same join per category.
            let frequencyCount = ((try? sqlite?.allFrequencyRecords(forCategoryID: id)) ?? []).count
            return CategorySummary(id: id, categoryName: category.categoryName,
                                   scanningEnabled: category.categoryScanningEnabled != 0,
                                   frequencyCount: frequencyCount)
        }
        return apiEncode(summaries)
    }

    /// All frequencies, unfiltered — the JSON-API equivalent of
    /// `favoritesTableHTML()`/`favorites.html`, not a per-category listing
    /// (there is no per-category `categoryID` populated here for the same
    /// reason `favorites.html` doesn't show one: a frequency can belong to
    /// several categories via the `FreqCat` join table, so "the" category
    /// isn't well-defined for a flat list).
    @MainActor private func apiFavoritesResponse() -> HTTPResponse {
        let frequencies = (try? sqlite?.allFrequencyRecords()) ?? []
        let summaries = frequencies.compactMap { f -> FrequencySummary? in
            guard let id = f.id else { return nil }
            return FrequencySummary(id: id, stationName: f.stationName,
                                    formattedFrequency: f.formattedFrequency, modulation: f.modulation)
        }
        return apiEncode(summaries)
    }

    /// The JSON-API equivalent of `/nowplayingstatus.html`, redesigned per
    /// `NowPlayingStatus`'s doc comment: a fixed set of fields instead of
    /// `nowPlayingStatusJSON()`'s full flattened `Frequency` record.
    @MainActor private func apiNowPlayingResponse() -> HTTPResponse {
        // TaskMode(rawValue:) round-tripping through SDRController.TaskMode's
        // rawValue is the drift guardrail described in AntennaHeadAPI's
        // TaskMode.swift: if the two enums' cases ever diverge, an unmapped
        // rawValue here silently becomes .stopped rather than failing to
        // build, so a case added to one without the other is a runtime gap,
        // not a compile error -- worth a follow-up if that's ever a problem.
        let mode = TaskMode(rawValue: sdrController?.taskMode.rawValue ?? "stopped") ?? .stopped
        let signalLevel = sdrController?.signalLevel ?? 0
        if let f = activeFrequencyRecord() {
            let status = NowPlayingStatus(taskMode: mode, stationName: f.stationName,
                                          formattedFrequency: f.formattedFrequency,
                                          statusText: sdrController?.statusFunction ?? "",
                                          signalLevel: signalLevel)
            return apiEncode(status)
        }
        let statusText = sdrController?.statusFunction ?? "Not Playing"
        let status = NowPlayingStatus(taskMode: mode, stationName: statusText, formattedFrequency: nil,
                                      statusText: statusText, signalLevel: signalLevel)
        return apiEncode(status)
    }

    /// The JSON-API equivalent of `/frequencylistenbuttonclicked.html`.
    /// Responds with the resulting `NowPlayingStatus` (rather than an empty
    /// 200, like the `.html` route) so a client can update its UI from one
    /// round trip instead of a tune-then-poll sequence.
    @MainActor private func apiTuneResponse(body: Data) -> HTTPResponse {
        guard let req = try? JSONDecoder().decode(TuneFrequencyRequest.self, from: body) else {
            return jsonErrorResponse("malformed request body", status: 400)
        }
        do {
            try sdrController?.startTasksForFrequency(id: req.frequencyID)
        } catch {
            return jsonErrorResponse("\(error)", status: 404)
        }
        return apiNowPlayingResponse()
    }

    /// The JSON-API equivalent of `/scannerlistenbuttonclicked.html`.
    @MainActor private func apiStartScanResponse(body: Data) -> HTTPResponse {
        guard let req = try? JSONDecoder().decode(StartCategoryScanRequest.self, from: body) else {
            return jsonErrorResponse("malformed request body", status: 400)
        }
        do {
            try sdrController?.startTasksForCategoryScan(id: req.categoryID)
        } catch {
            return jsonErrorResponse("\(error)", status: 404)
        }
        return apiNowPlayingResponse()
    }

    /// Stops whatever's currently running, regardless of task mode — the
    /// JSON-API equivalent of the various `*stop.html` routes
    /// (e.g. `controlboothstop.html`) collapsed into one, since
    /// a remote client has no reason to distinguish which source it's
    /// stopping the way each source's own web page does.
    @MainActor private func apiStopResponse() -> HTTPResponse {
        sdrController?.terminateTasks()
        return apiNowPlayingResponse()
    }

    /// Same data as `aacRecorderStatusResponse()` (`/api/aac-recorder/status`),
    /// re-served under the `/api/v1/` namespace as the typed
    /// `AACRecorderStatus` rather than that route's ad hoc dictionary — kept
    /// as a separate route rather than changing the existing one so the
    /// pre-existing route's response shape stays exactly as-is for whatever
    /// currently depends on it.
    @MainActor private func apiRecorderStatusResponse() -> HTTPResponse {
        let status = AACRecorderStatus(isRecording: liveAudioServerProcessManager?.isRecording ?? false,
                                       startedAt: liveAudioServerProcessManager?.recordingStartedAt)
        return apiEncode(status)
    }

    /// The JSON-API equivalent of `devicesFormHTML()`'s picker.
    @MainActor private func apiDevicesResponse() -> HTTPResponse {
        let summaries = AudioInputDevices.names().map { DeviceSummary(name: $0) }
        return apiEncode(summaries)
    }

    /// The JSON-API equivalent of `/devicelistenbuttonclicked.html`.
    /// `startTasksForDevice` doesn't throw (there's no "device not found" case
    /// — it's just a name handed to the capture pipeline), so this always
    /// succeeds from the caller's perspective.
    @MainActor private func apiStartDeviceResponse(body: Data) -> HTTPResponse {
        guard let req = try? JSONDecoder().decode(StartDeviceRequest.self, from: body) else {
            return jsonErrorResponse("malformed request body", status: 400)
        }
        sdrController?.startTasksForDevice(deviceName: req.deviceName, deviceAudioOutputFilter: req.audioOutputFilter)
        return apiNowPlayingResponse()
    }

    /// The JSON-API equivalent of `recordingsListHTML()`'s file listing —
    /// playback itself goes through the existing `/recordings-download/...`
    /// route (see `RecordingSummary.downloadPath`'s doc comment), not a new
    /// endpoint, since that route already gives Range-capable, seekable
    /// playback with the AAC-duration-estimate fix already applied.
    @MainActor private func apiRecordingsResponse() -> HTTPResponse {
        guard let folder = SharedRecordingFolder.url else {
            return apiEncode([RecordingSummary]())
        }
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { Self.recordingsFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let summaries = entries.map { url -> RecordingSummary in
            let name = url.lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return RecordingSummary(fileName: name, modifiedAt: modified,
                                    downloadPath: Self.recordingsDownloadPrefix + encodedName)
        }
        return apiEncode(summaries)
    }

    /// The JSON-API equivalent of `controlBoothPageHTML()`'s status portion.
    /// Pipeline names are only fetched when ControlBooth is actually running
    /// — `ControlBoothClient.pipelines()` talks to ControlBooth over
    /// AppleEvents, which has nothing to answer when it's not open.
    @MainActor private func apiControlBoothStatusResponse() -> HTTPResponse {
        let isRunning = ControlBoothClient.isControlBoothRunning
        let pipelines = isRunning ? ((try? ControlBoothClient.pipelines()) ?? []) : []
        return apiEncode(ControlBoothStatus(isRunning: isRunning, pipelineNames: pipelines))
    }

    /// The JSON-API equivalent of `/controlboothlaunched.html`. Launching is
    /// fire-and-forget (`launchControlBooth()` doesn't wait for the app to
    /// finish starting), so the returned status may still show `isRunning ==
    /// false` right after this call — same as the web page, which relies on
    /// its own "Refresh" button rather than blocking on launch.
    @MainActor private func apiControlBoothLaunchResponse() -> HTTPResponse {
        launchControlBooth()
        return apiControlBoothStatusResponse()
    }

    /// The JSON-API equivalent of `/controlboothlistenbuttonclicked.html`:
    /// stop whatever ControlBooth pipeline is already running, start
    /// AntennaHead's receiver, then start the new pipeline — same ordering
    /// as the HTML route, for the same reason (see that route's comment).
    @MainActor private func apiControlBoothStartResponse(body: Data) async -> HTTPResponse {
        guard let req = try? JSONDecoder().decode(StartControlBoothPipelineRequest.self, from: body) else {
            return jsonErrorResponse("malformed request body", status: 400)
        }
        try? ControlBoothClient.stopAllPipelines()
        await sdrController?.startControlBoothListening(name: req.pipelineName)
        try? ControlBoothClient.startPipeline(named: req.pipelineName)
        return apiNowPlayingResponse()
    }

    /// The JSON-API equivalent of `/controlboothstop.html`.
    @MainActor private func apiControlBoothStopResponse() -> HTTPResponse {
        try? ControlBoothClient.stopAllPipelines()
        sdrController?.terminateTasks()
        return apiNowPlayingResponse()
    }

    @MainActor private func controlBoothPageHTML() -> String {
        let isRunning = ControlBoothClient.isControlBoothRunning
        let statusText = isRunning ? "Running" : "Not running"
        let statusColor = isRunning ? "green" : "#cc0000"
        var s = "<div class='container'><section class='header'>"
        s += "<h2 class='title'>AntennaHead</h2>"
        s += "<h3 class='title' id='listen_title'>ControlBooth Remote Control</h3>"
        s += "<p>AntennaHead can be controlled remotely by the ControlBooth app on this Mac.</p>"
        // data-running is read by controlBoothPoll() (Web/js/antennahead.js)
        // so it can tell when this fragment's rendered status has gone
        // stale — e.g. ControlBooth quit after this page loaded — and
        // reload it, without any push channel from the server.
        s += "<p id='controlbooth_status' data-running='\(isRunning)'>ControlBooth: <strong style='color:\(statusColor)'>\(statusText)</strong></p>"
        if isRunning {
            let pipelines = (try? ControlBoothClient.pipelines()) ?? []
            if pipelines.isEmpty {
                s += "<p>No pipelines configured in ControlBooth.</p>"
            } else {
                s += "<form class='controlbooth_form' id='controlBoothForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
                s += "<label for='pipeline_select'>Select Pipeline:</label>"
                s += "<select name='pipeline_select' class='twelve columns value-prop' title='Select a ControlBooth pipeline to listen to.'>"
                for p in pipelines {
                    s += "<option value='\(htmlAttribute(p))'>\(htmlText(p))</option>"
                }
                s += "</select>"
                s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
                s += "onclick=\"controlBoothListenButtonClicked(getElementById('controlBoothForm'));\" "
                s += "title='Start listening to the selected ControlBooth pipeline.'>"
                s += "</form><br>&nbsp;<br>"
                s += "<form action='javascript:loadContent(&quot;controlboothstop.html&quot;)'>"
                s += "<input class='twelve columns button' type='submit' value='Stop'></form><br>&nbsp;<br>"
            }
        } else {
            s += "<form action='javascript:loadContent(&quot;controlboothlaunched.html&quot;)'>"
            s += "<input class='twelve columns button button-primary' type='submit' value='Launch ControlBooth'>"
            s += "</form><br>&nbsp;<br>"
        }
        s += "<br><input class='button' type='button' value='Refresh' onclick=\"loadContent('controlbooth.html');\"><br>&nbsp;<br>"
        s += "</section></div>"
        return s
    }

    /// Launches the ControlBooth app using the security-scoped bookmark saved
    /// by ConfigurationView's file picker, falling back to the stored path.
    @MainActor private func launchControlBooth() {
        if let base64 = (try? sqlite?.appSettingsValue(forKey: "AntennaHeadControlBoothBookmark")) ?? nil,
           let data = Data(base64Encoded: base64) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let accessed = url.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open(url)
                if accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
        }
        let path = ((try? sqlite?.appSettingsValue(forKey: "AntennaHeadControlBoothAppPath")) ?? nil)
            ?? "/Applications/ControlBooth.app"
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
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

    /// `%%CATEGORIES_TABLE%%` — ported from `generateCategoriesString`. Lists all
    /// categories (each ID links to `category.html?id=N`) plus an "Add New
    /// Category" button that loads `addcategoryform.html`.
    @MainActor private func categoriesTableHTML() -> String {
        let categories = (try? sqlite?.allCategoryRecords()) ?? []
        var s = "<table class='u-full-width'><thead><tr><th>ID</th><th>Category</th></tr></thead><tbody>"
        for c in categories {
            guard let id = c.id else { continue }
            let title = "Show category \(c.categoryName)"
            s += "<tr><td>"
            s += "<a class='button button-primary' type='submit' onclick=\"loadContent('category.html?id=\(id)');\" title='\(htmlAttribute(title))'>\(id)</a>"
            s += "</td><td>\(htmlText(c.categoryName))</td></tr>"
        }
        s += "</tbody></table>"
        s += "<form class='new-category-form' id='new-category-form' action='javascript:loadContent(&quot;addcategoryform.html&quot;)'>"
        s += "<br>&nbsp;<br>&nbsp;<br>\n"
        s += "<input id='add-category-button' class='twelve columns button button-primary' type='submit' value='Add New Category'>\n"
        s += "</form>\n<br>&nbsp;<br>\n"
        return s
    }

    /// `%%CATEGORY_SELECT%%` — a category pop-up (used by the Tuner sub-category
    /// pages to file a newly-tuned frequency under a category). Ported from
    /// `generateCategorySelectOptions`; leading blank option = "no category".
    @MainActor private func categorySelectOptionsHTML() -> String {
        let categories = (try? sqlite?.allCategoryRecords()) ?? []
        var s = "<label for='categories_select'>Category:</label>"
        s += "<select class='twelve columns value-prop' name='categories_select' "
        s += "title='The Category pop-up button can be used when adding a new Favorites frequency record'>"
        s += "<option value='' selected></option>"
        for c in categories {
            guard let id = c.id else { continue }
            s += "<option value='\(id)'>\(htmlText(c.categoryName))</option>"
        }
        s += "</select>"
        return s
    }

    // MARK: Settings page (system-wide output bitrate)

    /// `%%AAC_BITRATE_SELECT%%` — `<option>`s for the output bitrate pop-up,
    /// with the stored `app_config` value selected.
    @MainActor private func outputBitrateSelectOptionsHTML() -> String {
        let current = Self.storedOutputBitrate(sqlite: sqlite)
        var s = ""
        for bps in Self.outputBitrateOptions {
            s += "<option value='\(bps)'\(bps == current ? " selected" : "")>\(bps / 1000) kbps</option>"
        }
        return s
    }

    /// `%%WEB_UI_THEME_SELECT%%` — `<option>`s for the colour-scheme pop-up,
    /// with the stored `app_config` value selected.
    @MainActor private func webUIThemeSelectOptionsHTML() -> String {
        let current = Self.storedWebUITheme(sqlite: sqlite)
        let labels = ["auto": "Auto (match system)", "light": "Light", "dark": "Dark"]
        var s = ""
        for value in Self.webUIThemeOptions {
            s += "<option value='\(value)'\(value == current ? " selected" : "")>\(labels[value] ?? value)</option>"
        }
        return s
    }

    // MARK: Recordings page (browse + play files from the shared Recordings folder)

    /// Audio file extensions listed on the Recordings page — everything
    /// AntennaHead's own AAC recorder and ControlBooth's LiveAudioRecorder
    /// helper can produce, plus the common formats `PCMFilePlayer` (backed by
    /// `AVAudioFile`) can decode.
    nonisolated private static let recordingsFileExtensions: Set<String> = ["aac", "mp3", "m4a", "wav", "caf"]

    /// Route prefix for the fast-download playback route (see
    /// `recordingDownloadResponse`) — the bare filename is appended,
    /// percent-encoded, e.g. `/recordings-download/AntennaHead-2026...aac`.
    nonisolated private static let recordingsDownloadPrefix = "/recordings-download/"

    /// Where `remuxedM4A(forRecordingAt:)` caches its output. Lives in this
    /// (sandboxed) app's own Caches directory rather than the shared App
    /// Group Recordings folder — it's a derived playback convenience, not a
    /// recording itself, so ControlBooth and other App Group readers of that
    /// folder shouldn't see it. `nil` only if Caches itself is unavailable.
    nonisolated private static var recordingsDownloadCacheFolder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = caches.appendingPathComponent("RecordingsDownloadCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `%%RECORDINGS_LIST%%` — filter/sort controls, the file table, a Repeat
    /// checkbox, and the Listen button. Sorting/filtering happens client-side
    /// (`js/antennahead.js`) against the `data-name`/`data-date` attributes
    /// rendered on each row, so no round trip is needed while typing.
    @MainActor private func recordingsListHTML() -> String {
        guard let folder = SharedRecordingFolder.url else {
            return "<p>AntennaHead's shared Recordings folder isn't available — check its App Group entitlement.</p>"
        }
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { Self.recordingsFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        // Compact byte count shown next to each name, e.g. "(19.8 MB)". Cheap
        // (a stat, already in the resource-values fetch above) — unlike a
        // playing-time column, which would need a per-file AVAsset probe on
        // every page load and, for this app's raw ADTS `.aac` recordings,
        // couldn't be trusted anyway (no container duration box — see the
        // estimate quirk noted in `recordingDownloadResponse`).
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        byteFormatter.allowedUnits = [.useKB, .useMB, .useGB]

        var rows = ""
        for (index, url) in entries.enumerated() {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let byteCount = values?.fileSize ?? 0
            let sizeText = byteFormatter.string(fromByteCount: Int64(byteCount))
            let rowID = "rec-\(index)"
            rows += "<tr class='recording-row' data-name='\(htmlAttribute(name.lowercased()))' "
            rows += "data-date='\(modified.timeIntervalSince1970)' data-size='\(byteCount)'>"
            rows += "<td><input type='radio' name='selected_file' id='\(rowID)' value='\(htmlAttribute(name))'></td>"
            rows += "<td><label for='\(rowID)'>\(htmlText(name)) "
            rows += "<span class='rec-size'>(\(htmlText(sizeText)))</span></label></td>"
            rows += "<td>\(htmlText(df.string(from: modified)))</td>"
            rows += "</tr>"
        }
        if rows.isEmpty {
            rows = "<tr><td colspan='3'>No recordings found.</td></tr>"
        }

        var s = "<form class='recordings_form' id='recordingsForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
        s += "<label for='recordings_filter'>Filter:</label>"
        s += "<input class='twelve columns value-prop' type='text' \(Self.verbatimInputAttributes) id='recordings_filter' "
        s += "oninput='filterRecordingsTable();' placeholder='Filter by name…' title='Narrows the list below to names containing this text.'>"
        s += "<label for='recordings_sort'>Sort By:</label>"
        s += "<select id='recordings_sort' class='twelve columns value-prop' onchange='sortRecordingsTable();' title='Choose how the list below is ordered.'>"
        s += "<option value='name'>Name</option>"
        s += "<option value='date'>Date (Newest First)</option>"
        s += "<option value='size'>Size (Largest First)</option>"
        s += "</select>"
        s += "<table class='u-full-width' id='recordingsTable'>"
        s += "<thead><tr><th></th><th>Name</th><th>Date</th></tr></thead>"
        s += "<tbody id='recordingsTableBody'>\(rows)</tbody>"
        s += "</table>"
        s += "<label for='recordings_repeat' title='Loop the selected file continuously until you play something else.'>"
        s += "<input type='checkbox' id='recordings_repeat' name='repeat_flag' value='1'> Repeat continuously</label>"
        s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"recordingListenButtonClicked(getElementById('recordingsForm'));\" "
        s += "title='Stream the selected recording through the live audio pipeline. No seeking, but you can switch away and back at any time.'>"
        s += "<br><input class='twelve columns button' type='button' value='Download &amp; Play' "
        s += "onclick=\"recordingDownloadButtonClicked(getElementById('recordingsForm'));\" "
        s += "title='Download the selected recording and play it directly, so you can drag the seek bar to any point. Playback just stops at the end of the file — unlike Listen, there is no live stream to fall back to. Not available for .caf files.'>"
        s += "</form><br>&nbsp;<br>"
        return s
    }

    // MARK: Devices page (audio-input + custom-task forms)

    /// `%%DEVICES_FORM%%` — Core Audio input picker + output filter + Listen.
    /// Ported from `generateDevicesFormString`.
    @MainActor private func devicesFormHTML() -> String {
        var s = "<form class='device_form' id='deviceForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
        s += "<label for='audio_input'>Select Audio Input:</label>"
        s += "<select name='audio_input' class='twelve columns value-prop' title='Selects a Core Audio input device, like &quot;Built-in Microphone&quot;.'>"
        for name in AudioInputDevices.names() {
            s += "<option value='\(htmlAttribute(name))'>\(htmlText(name))</option>"
        }
        s += "</select>"
        s += "<label for='audio_output_filter'>Sox Audio Output Filter:</label>"
        s += "<input class='twelve columns value-prop' type='text' \(Self.verbatimInputAttributes) id='audio_output_filter' name='audio_output_filter' value='vol 1' "
        s += "title='Applied by the Sox audio tool to the final output. Default &quot;vol 1&quot;. Do not set a &quot;rate&quot; here — the sample rate is fixed at 48000.'>"
        s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"deviceListenButtonClicked(getElementById('deviceForm'));\" "
        s += "title='Listen to the selected audio input device.'>"
        s += "</form><br>&nbsp;<br>"
        return s
    }

    /// `%%GQRX_FORM%%` — starts a PCMUDPReceiver (port 7355) → sox → PCMUDPSender
    /// bridge. Sox normalizes to 48 kHz/2ch; `channels` must match Gqrx's
    /// Audio→Stereo setting (see `SDRController.startGqrxListening`).
    @MainActor private func gqrxFormHTML() -> String {
        let gqrxPort = sdrController?.gqrxReceivePort ?? 7355
        var s = "<form class='gqrx_form' id='gqrxForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
        s += "<label>Listen to Gqrx</label>"
        s += "<p>Receiving on UDP port <strong>\(gqrxPort)</strong> — set Gqrx's Audio ▸ UDP output to this port.</p>"
        s += "<label>Channels</label>"
        s += "<select class='u-full-width' name='gqrx_channels'>"
        s += "<option value='2'>2 – Stereo (Gqrx Audio ▸ Stereo checkbox enabled)</option>"
        s += "<option value='1'>1 – Mono</option>"
        s += "</select>"
        s += "<input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"gqrxListenButtonClicked(this.form);\" "
        s += "title='Receive Gqrx&#39;s UDP audio output (port \(gqrxPort)), normalize via sox, forward to LiveAudioServer.'>"
        s += "</form><br>&nbsp;<br>"
        return s
    }

    /// `%%TEXT_TO_SPEECH_FORM%%` — a persistent folder setting (chosen with a
    /// native NSOpenPanel via `/texttospeechchoosefolder.html`), an order, and a
    /// repeat toggle, then Listen. `/texttospeechlistenbuttonclicked.html`
    /// resolves the saved security-scoped bookmark, reads the folder's `.txt`
    /// files, and hands them to `SDRController.startTextToSpeech` → PCMSpeechSynth
    /// → sox → PCMUDPSender.
    @MainActor private func textToSpeechFormHTML() -> String {
        let storedPath = ((try? sqlite?.appSettingsValue(forKey: Self.textToSpeechFolderPathKey)) ?? nil) ?? ""
        let folderLabel = storedPath.isEmpty ? "No folder selected." : storedPath

        var s = "<form class='text_to_speech_form' id='textToSpeechForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
        s += "<label>Text to Speech</label>"
        s += "<p>Speak the <code>.txt</code> files from a folder through the live audio pipeline "
        s += "(<code>PCMSpeechSynth</code> synthesizes each one in turn).</p>"
        s += "<label for='tts_folder_status'>Text Files Folder</label>"
        s += "<p id='tts_folder_status' class='tts-folder-path'>\(htmlText(folderLabel))</p>"
        s += "<input class='twelve columns button' type='button' value='Select Text Folder…' "
        s += "onclick='textToSpeechChooseFolderButtonClicked();' "
        s += "title='Open a folder chooser on the Mac running AntennaHead and press Select. The choice is remembered.'>"
        s += "<label for='tts_sequence'>Sequence</label>"
        s += "<select id='tts_sequence' name='tts_sequence' class='u-full-width' "
        s += "title='Chronological plays the oldest file first; Random shuffles the order.'>"
        s += "<option value='chronological'>Chronological (oldest file first)</option>"
        s += "<option value='random'>Random</option>"
        s += "</select>"
        s += "<label for='tts_repeat' title='Loop through the folder continuously until you play something else.'>"
        s += "<input type='checkbox' id='tts_repeat' name='tts_repeat' value='1'> Repeat indefinitely</label>"
        s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"textToSpeechListenButtonClicked(getElementById('textToSpeechForm'));\" "
        s += "title='Synthesize the selected folder&#39;s text files and stream them through the live audio pipeline.'>"
        s += "</form><br>&nbsp;<br>"
        return s
    }

    /// Runs a native folder chooser on the host Mac and, on "Select", persists
    /// the choice as a security-scoped bookmark plus a plain path (same storage
    /// pattern as ConfigurationView's ControlBooth picker). Returns the saved
    /// path — the freshly chosen one, or the previously stored value if the
    /// user cancels — for the web UI to display.
    @MainActor private func chooseTextToSpeechFolder() -> String {
        let stored = ((try? sqlite?.appSettingsValue(forKey: Self.textToSpeechFolderPathKey)) ?? nil) ?? ""

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the folder that holds the text (.txt) files to speak"
        if !stored.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: stored)
        }
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return stored }

        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? sqlite?.storeAppSettingsValue(data.base64EncodedString(),
                                               forKey: Self.textToSpeechFolderBookmarkKey)
        }
        try? sqlite?.storeAppSettingsValue(url.path, forKey: Self.textToSpeechFolderPathKey)
        return url.path
    }

    /// Resolves the saved Text-to-Speech folder bookmark and reads its `.txt`
    /// files (name, modification date, contents) while holding security-scoped
    /// access. Returns `[]` when no folder is configured or it can't be read.
    @MainActor private func textToSpeechFolderFiles() -> [SDRController.SpeechTextFile] {
        guard let base64 = (try? sqlite?.appSettingsValue(forKey: Self.textToSpeechFolderBookmarkKey)) ?? nil,
              let data = Data(base64Encoded: base64) else {
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer",
                                "Text to Speech: no folder selected — use \"Select Text Folder…\" first")
            return []
        }
        var isStale = false
        guard let folderURL = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                       relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer",
                                "Text to Speech: saved folder bookmark could not be resolved — re-select the folder")
            return []
        }
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        if isStale, let fresh = try? folderURL.bookmarkData(options: .withSecurityScope,
                                                           includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? sqlite?.storeAppSettingsValue(fresh.base64EncodedString(),
                                               forKey: Self.textToSpeechFolderBookmarkKey)
        }

        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var files: [SDRController.SpeechTextFile] = []
        var totalCharacters = 0
        for url in entries {
            guard files.count < Self.textToSpeechMaxFiles,
                  totalCharacters < Self.textToSpeechMaxTotalCharacters else {
                LogStore.shared.log(.info, source: "AntennaHeadHTTPServer",
                                    "Text to Speech: folder has more text than the \(Self.textToSpeechMaxFiles)-file / "
                                    + "\(Self.textToSpeechMaxTotalCharacters)-character cap — speaking the first part only")
                break
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append(SDRController.SpeechTextFile(name: url.lastPathComponent, modified: modified, text: text))
            totalCharacters += text.count
        }
        if files.isEmpty {
            LogStore.shared.log(.error, source: "AntennaHeadHTTPServer",
                                "Text to Speech: no readable .txt files in \(folderURL.path)")
        }
        return files
    }

    // MARK: Shared HTML helpers

    /// Fragment returned for pages that have no `%%…%%` template file. Loaded
    /// into index.html's content_frame by `loadContent`, so it uses the site CSS.
    nonisolated private func htmlFragmentResponse(_ html: String) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK",
                     headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: Data(html.utf8))
    }

    /// Attributes that stop WebKit's smart quotes/dashes and autocorrect from
    /// mangling command-line text ("--text" would otherwise become an em dash).
    nonisolated static let verbatimInputAttributes =
        "autocomplete='off' autocorrect='off' autocapitalize='none' spellcheck='false'"

    // MARK: Tuner (advanced form + insert-new-frequency)

    /// `%%TUNER_FORM%%` for tuner_advanced.html — a full new-frequency form whose
    /// field names match the `frequency` table columns. Submits (via
    /// `insertNewFrequencyRecord`) to insertnewfrequency.html.
    @MainActor private func newFrequencyFormHTML() -> String {
        let p = Frequency.prototype()

        func text(_ label: String, _ name: String, _ value: String, type: String = "text", step: String? = nil, list: String? = nil) -> String {
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            let listAttr = list.map { " list='\($0)'" } ?? ""
            return "<label for='\(name)'>\(label)</label><input class='twelve columns value-prop' type='\(type)' \(Self.verbatimInputAttributes) "
                + "id='\(name)' name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)\(listAttr)>"
        }
        func select(_ label: String, _ name: String, _ current: String, _ options: [(value: String, label: String)]) -> String {
            var s = "<label for='\(name)'>\(label)</label><select class='twelve columns value-prop' name='\(name)'>"
            for opt in options {
                s += "<option value='\(htmlAttribute(opt.value))'\(opt.value == current ? " selected" : "")>\(htmlText(opt.label))</option>"
            }
            return s + "</select>"
        }
        let onOff = [("0", "Off"), ("1", "On")]
        let modulationOptions = Frequency.modulationOptions.map { ($0, $0.uppercased()) }

        var s = "<form class='wbfm-tuner-form' id='tuner-advanced-form' onsubmit='event.preventDefault(); return insertNewFrequencyRecord(this);' method='POST'>"
        s += text("Station Name:", "station_name", "")
        s += text("Frequency (Hz):", "frequency", "\(p.frequency)", type: "number")
        s += select("Modulation:", "modulation", p.modulation, modulationOptions)
        s += select("FM Stereo:", "stereo_flag", p.stereoFlag ? "1" : "0", onOff)
        s += text("Sample Rate:", "sample_rate", "\(p.sampleRate)", type: "number")
        s += text("Tuner Gain:", "tuner_gain", "\(p.tunerGain)", type: "number", step: "0.1")
        s += select("Tuner AGC:", "tuner_agc", "\(p.tunerAgc)", onOff)
        s += select("Sampling Mode:", "sampling_mode", "\(p.samplingMode)",
                    [("0", "Standard"), ("1", "Direct Sampling (I)"), ("2", "Direct Sampling (Q)")])
        s += text("Oversampling:", "oversampling", "\(p.oversampling)", type: "number")
        s += text("Squelch Level:", "squelch_level", "\(p.squelchLevel)", type: "number", step: "0.1")
        s += text("FIR Size:", "fir_size", "\(p.firSize)", type: "number")
        s += text("atan Math:", "atan_math", p.atanMath)
        s += text("Audio Output Filter:", "audio_output_filter", p.audioOutputFilter)
        s += text("rtl_fm Options:", "options", p.options)
        s += text("USB Device (serial number or index):", "usb_device_string", formattedUSBDeviceValue(p.usbDeviceString), list: "usb_device_datalist")
        s += "<datalist id='usb_device_datalist'></datalist>"
        s += select("Bias-T Power:", "bias_t_flag", "\(p.biasTFlag)", onOff)
        s += categorySelectOptionsHTML()
        s += "<br>&nbsp;<br>&nbsp;<br>"
        s += "<input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick='advancedListenButtonClicked(this.form);' "
        s += "title='Tune the RTL-SDR radio to the frequency and settings above.'>"
        s += "<br>&nbsp;<br>&nbsp;<br>"
        s += "<input class='twelve columns button button-primary' type='submit' value='Add New Favorite Frequency'>"
        s += "</form>"
        return s
    }

    /// Inserts a new `frequency` record from a Tuner form (insertnewfrequency.html),
    /// optionally filing it under the `categories_select` category.
    @MainActor private func insertNewFrequency(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        var f = Frequency.prototype()
        if let v = fields["station_name"], !v.isEmpty { f.stationName = v }
        if let v = fields["frequency"], let n = Int(v) { f.frequency = n }
        if let v = fields["frequency_mode"] { f.frequencyMode = (v == "frequency_mode_range" || v == "1") ? 1 : 0 }
        if let v = fields["frequency_scan_end"], let n = Int(v) { f.frequencyScanEnd = n }
        if let v = fields["frequency_scan_interval"], let n = Int(v) { f.frequencyScanInterval = n }
        if let v = fields["modulation"] { f.modulation = v }
        if let v = fields["stereo_flag"] { f.stereoFlag = (v == "1") }
        if let v = fields["sample_rate"], let n = Int(v) { f.sampleRate = n }
        if let v = fields["tuner_gain"], let n = Double(v) { f.tunerGain = n }
        if let v = fields["tuner_agc"], let n = Int(v) { f.tunerAgc = n }
        if let v = fields["sampling_mode"], let n = Int(v) { f.samplingMode = n }
        if let v = fields["oversampling"], let n = Int(v) { f.oversampling = n }
        if let v = fields["squelch_level"], let n = Double(v) { f.squelchLevel = n }
        if let v = fields["fir_size"], let n = Int(v) { f.firSize = n }
        if let v = fields["atan_math"] { f.atanMath = v }
        if let v = fields["audio_output_filter"] { f.audioOutputFilter = v }
        if let v = fields["options"] { f.options = v }
        if let v = fields["usb_device_string"] { f.usbDeviceString = v }
        if let v = fields["bias_t_flag"], let n = Int(v) { f.biasTFlag = n }

        guard let newID = try? sqlite?.insertFrequencyRecord(&f) else { return }
        if let cidString = fields["categories_select"], let cid = Int64(cidString) {
            try? sqlite?.insertFreqCatRecord(forFrequencyID: newID, categoryID: cid)
        }
    }

    // MARK: Category page tree (category.html and its edit/add/delete routes)

    /// `%%SCAN_CATEGORY_BUTTON%%` — a "Scan All Frequencies" button, only when
    /// the category has scanning enabled. Posts to scannerlistenbuttonclicked.html.
    @MainActor private func scanCategoryButtonHTML(category c: Category) -> String {
        guard c.categoryScanningEnabled == 1, let id = c.id else { return "" }
        var s = "<form id='scannerlistenForm' action='#'>"
        s += "<input type='hidden' name='id' value='\(id)'>"
        s += "<br><input class='twelve columns button button-primary' type='button' value='Scan All Frequencies' "
        s += "onclick=\"scannerListenButtonClicked(scannerlistenForm);\">"
        s += "</form><br>&nbsp;<br>\n"
        return s
    }

    /// `%%EDIT_CATEGORY_LIST_BUTTON%%` / `%%CATEGORY_SETTINGS_BUTTON%%` — a button
    /// that loads another category page for this id.
    private func categoryNavButtonHTML(page: String, id: Int64, label: String) -> String {
        "<form action='javascript:loadContent(&quot;\(page)?id=\(id)&quot;)'>"
            + "<input class='button twelve columns' type='submit' value='\(htmlText(label))'>"
            + "<input type='hidden' name='id' value='\(id)'></form><br>&nbsp;<br>\n"
    }

    /// `%%CATEGORY_TABLE%%` — frequencies belonging to a category, each linking to
    /// its view page. Ported from `generateCategoryFavoritesString`.
    @MainActor private func categoryFavoritesTableHTML(categoryID: Int64) -> String {
        let frequencies = (try? sqlite?.allFrequencyRecords(forCategoryID: categoryID)) ?? []
        var s = "<table class='u-full-width'><thead><tr><th>Frequency</th><th>Name</th></tr></thead><tbody>"
        for f in frequencies {
            guard let id = f.id else { continue }
            s += "<tr><td>"
            s += "<a class='button button-primary two columns' type='submit' onclick=\"loadContent('viewfavorite.html?id=\(id)');\">\(htmlText(f.formattedFrequency))</a>"
            s += "</td><td>\(htmlText(f.stationName))</td></tr>"
        }
        s += "</tbody></table>"
        return s
    }

    /// `%%EDIT_CATEGORY_TABLE%%` — every frequency with a membership checkbox for
    /// this category. Ported from `generateEditCategoryString`.
    @MainActor private func editCategoryTableHTML(categoryID: Int64) -> String {
        let frequencies = (try? sqlite?.allFrequencyRecords()) ?? []
        var s = "<table class='u-full-width'><thead><tr><th>ID</th><th>Frequency</th><th>Name</th></tr></thead><tbody>"
        for f in frequencies {
            guard let id = f.id else { continue }
            let isMember = (try? sqlite?.freqCatRecordExists(forFrequencyID: id, categoryID: categoryID)) ?? false
            let checked = isMember ? " checked" : ""
            s += "<tr><td>"
            s += "<input type='checkbox' class='checkbox' onclick='handleEditCategoryClick(this);' cat_id='\(categoryID)' freq_id='\(id)'\(checked)></td>"
            s += "<td>\(htmlText(f.formattedFrequency))</td><td>\(htmlText(f.stationName))</td></tr>"
        }
        s += "</tbody></table>"
        return s
    }

    /// `%%DELETE_CATEGORY_BUTTON%%` — ported from `generateDeleteCategoryButtonStringForID`.
    private func deleteCategoryButtonHTML(categoryID: Int64, name: String) -> String {
        var label = name
        if label.count > 25 { label = String(label.prefix(25)) + "..." }
        var s = "<form class='delete-favorite-form' id='delete-favorite-form' onsubmit='event.preventDefault(); return deleteCategoryRecord(this);' method='POST'>\n"
        s += "<br>&nbsp;<br>&nbsp;<br>\n"
        s += "<input id='delete-category-button' class='twelve columns button button-primary' type='submit' value='Delete \(htmlText(label)) Category'>\n"
        s += "<input type='hidden' id='category_id' name='category_id' value='\(categoryID)'>\n"
        s += "<input type='hidden' id='category_name' name='category_name' value='\(htmlAttribute(name))'>\n"
        s += "</form>\n<br>&nbsp;<br>\n"
        return s
    }

    /// `%%EDIT_CATEGORY_SETTINGS%%` — the category scan-settings form. Field names
    /// match the `category` table columns; Save posts to storecategory.html.
    /// Ported (simplified to plain inputs) from `generateEditCategorySettingsStringForID`.
    private func editCategorySettingsFormHTML(category c: Category) -> String {
        guard let id = c.id else { return "Error getting category" }

        func text(_ label: String, _ name: String, _ value: String, type: String = "text", step: String? = nil, list: String? = nil) -> String {
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            let listAttr = list.map { " list='\($0)'" } ?? ""
            return "<label for='\(name)'>\(label)</label><input class='twelve columns value-prop' type='\(type)' \(Self.verbatimInputAttributes) "
                + "id='\(name)' name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)\(listAttr)>"
        }
        func select(_ label: String, _ name: String, _ current: String, _ options: [(value: String, label: String)]) -> String {
            var s = "<label for='\(name)'>\(label)</label><select class='twelve columns value-prop' name='\(name)'>"
            for opt in options {
                s += "<option value='\(htmlAttribute(opt.value))'\(opt.value == current ? " selected" : "")>\(htmlText(opt.label))</option>"
            }
            return s + "</select>"
        }
        let onOff = [("0", "Off"), ("1", "On")]
        let modulationOptions = Frequency.modulationOptions.map { ($0, $0.uppercased()) }

        var s = "<form class='editcategorysettings' id='editcategorysettings' onsubmit='event.preventDefault(); return storeCategoryRecord(this);' method='POST'>"
        s += text("Name:", "category_name", c.categoryName)
        s += select("Enable Category Scanning:", "category_scanning_enabled", "\(c.categoryScanningEnabled)", [("0", "Disabled"), ("1", "Enabled")])
        s += text("USB Device (serial number or index):", "scan_usb_device_string", formattedUSBDeviceValue(c.scanUsbDeviceString), list: "usb_device_datalist")
        s += "<datalist id='usb_device_datalist'></datalist>"
        s += text("Tuner Gain:", "scan_tuner_gain", "\(c.scanTunerGain)", type: "number", step: "0.1")
        s += select("Tuner AGC:", "scan_tuner_agc", "\(c.scanTunerAgc)", onOff)
        s += text("Sample Rate:", "scan_sample_rate", "\(c.scanSampleRate)", type: "number")
        s += select("Sampling Mode:", "scan_sampling_mode", "\(c.scanSamplingMode)",
                    [("0", "Standard"), ("1", "Direct Sampling (I)"), ("2", "Direct Sampling (Q)")])
        s += text("Oversampling:", "scan_oversampling", "\(c.scanOversampling)", type: "number")
        s += select("Modulation:", "scan_modulation", c.scanModulation, modulationOptions)
        s += text("Squelch Level:", "scan_squelch_level", "\(c.scanSquelchLevel)", type: "number", step: "0.1")
        s += text("Squelch Delay:", "scan_squelch_delay", "\(c.scanSquelchDelay)", type: "number", step: "0.1")
        s += text("RTL-FM Options:", "scan_options", c.scanOptions)
        s += text("FIR Size:", "scan_fir_size", "\(c.scanFirSize)", type: "number")
        s += text("atan Math:", "scan_atan_math", c.scanAtanMath)
        s += text("Sox Audio Output Filter:", "scan_audio_output_filter", c.scanAudioOutputFilter)
        s += select("Bias-T Power:", "scan_bias_t_flag", "\(c.scanBiasTFlag)", onOff)
        s += "<input type='hidden' name='id' value='\(id)'>"
        s += "<br>&nbsp;<br>&nbsp;<br><input class='twelve columns button button-primary' type='submit' value='Save Changes'>"
        s += "</form><br>&nbsp;<br>&nbsp;"
        return s
    }

    /// Toggles a frequency's membership in a category (editcategoryitem.html).
    @MainActor private func toggleCategoryItem(catID: Int64, freqID: Int64, isMember: Bool) {
        let exists = (try? sqlite?.freqCatRecordExists(forFrequencyID: freqID, categoryID: catID)) ?? false
        if isMember, !exists {
            try? sqlite?.insertFreqCatRecord(forFrequencyID: freqID, categoryID: catID)
        } else if !isMember, exists {
            try? sqlite?.deleteFreqCatRecord(forFrequencyID: freqID, categoryID: catID)
        }
    }

    /// Creates a category from the add form (addcategory.html), skipping if a
    /// category with the same name already exists.
    @MainActor private func addCategory(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        let name = (fields["category_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if (try? sqlite?.categoryRecord(forName: name)) != nil { return }
        var record = Category.prototype(name: name)
        _ = try? sqlite?.insertCategoryRecord(&record)
    }

    /// Applies edited scan settings to a category (storecategory.html). Unlisted
    /// fields keep their stored values.
    @MainActor private func saveCategory(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        guard let idString = fields["id"], let id = Int64(idString),
              var c = (try? sqlite?.categoryRecord(forID: id)) ?? nil else { return }

        if let v = fields["category_name"] { c.categoryName = v }
        if let v = fields["category_scanning_enabled"], let n = Int(v) { c.categoryScanningEnabled = n }
        if let v = fields["scan_usb_device_string"] { c.scanUsbDeviceString = v }
        if let v = fields["scan_tuner_gain"], let n = Double(v) { c.scanTunerGain = n }
        if let v = fields["scan_tuner_agc"], let n = Int(v) { c.scanTunerAgc = n }
        if let v = fields["scan_sample_rate"], let n = Int(v) { c.scanSampleRate = n }
        if let v = fields["scan_sampling_mode"], let n = Int(v) { c.scanSamplingMode = n }
        if let v = fields["scan_oversampling"], let n = Int(v) { c.scanOversampling = n }
        if let v = fields["scan_modulation"] { c.scanModulation = v }
        if let v = fields["scan_squelch_level"], let n = Double(v) { c.scanSquelchLevel = n }
        if let v = fields["scan_squelch_delay"], let n = Double(v) { c.scanSquelchDelay = n }
        if let v = fields["scan_options"] { c.scanOptions = v }
        if let v = fields["scan_fir_size"], let n = Int(v) { c.scanFirSize = n }
        if let v = fields["scan_atan_math"] { c.scanAtanMath = v }
        if let v = fields["scan_audio_output_filter"] { c.scanAudioOutputFilter = v }
        if let v = fields["scan_bias_t_flag"], let n = Int(v) { c.scanBiasTFlag = n }

        try? sqlite?.updateCategoryRecord(c)
    }

    /// Deletes the category identified by the posted form's `category_id`.
    @MainActor private func deleteCategory(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        if let idString = fields["category_id"], let id = Int64(idString) {
            try? sqlite?.deleteCategoryRecord(forID: id)
        }
    }

    // MARK: Radio-player status lines

    /// Demodulated audio channel count for a tuning — 2 only when FM-stereo
    /// decoding actually engages (matches `SDRController.startPipeline`'s
    /// `isStereo` test), otherwise 1. The delivered stream is always 2 ch.
    nonisolated private func demodulatedChannelCount(modulation: String, stereoFlag: Bool, sampleRate: Int) -> Int {
        ((modulation == "fm" || modulation == "wfm") && stereoFlag && sampleRate > 106_000) ? 2 : 1
    }

    /// "1 (mono)" / "2 (stereo)" for a channel count.
    nonisolated private func channelsLabel(_ count: Int) -> String {
        switch count {
        case 1: return "1 (mono)"
        case 2: return "2 (stereo)"
        default: return "\(count)"
        }
    }

    /// rtl_fm tuner-gain readout: a plain dB value, "auto" for a non-positive
    /// gain, with ", AGC on" appended when the tuner's internal AGC is enabled.
    nonisolated private func gainLabel(gain: Double, agc: Bool) -> String {
        let base: String
        if gain <= 0 {
            base = "auto"
        } else if gain.truncatingRemainder(dividingBy: 1) == 0 {
            base = "\(Int(gain)) dB"
        } else {
            base = "\(gain) dB"
        }
        return agc ? "\(base), AGC on" : base
    }

    /// "device:" line for the Now Playing views: the RTL-SDR dongle feeding the
    /// active tuning, resolved to its EEPROM serial and USB index at tune time
    /// by `SDRController`. Falls back to the value the favorite stores when
    /// nothing is tuned or the configured device isn't connected.
    @MainActor private func activeDeviceLabel(stored: String) -> String {
        let storedLabel = formattedUSBDeviceValue(stored)
        guard let sdr = sdrController, sdr.taskMode != .stopped else { return storedLabel }
        let serial = sdr.activeDeviceSerial
        let index = sdr.activeDeviceIndex
        if serial.isEmpty && index < 0 {
            return storedLabel.isEmpty ? "not connected" : "\(storedLabel) (not connected)"
        }
        var parts: [String] = []
        if !serial.isEmpty { parts.append("serial \(serial)") }
        parts.append(index >= 0 ? "USB index \(index)" : "USB index unknown")
        return parts.joined(separator: ", ")
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
        s += "<input class='twelve columns button' type='button' value='Edit' "
        s += "onclick=\"loadContent('editfavorite.html?id=\(id)');\" "
        s += "title='Click Edit to modify this favorite.'>"

        // When this favorite is the one currently on the air, show the live
        // resolved device and channel count; otherwise show what the record
        // itself specifies. The Now Playing page always has the live view.
        let isOnAir = sdrController?.activeFrequencyID == id && sdrController?.taskMode != .stopped
        let deviceLabel = isOnAir
            ? activeDeviceLabel(stored: f.usbDeviceString)
            : (formattedUSBDeviceValue(f.usbDeviceString).isEmpty ? "0" : formattedUSBDeviceValue(f.usbDeviceString))
        let channels = isOnAir
            ? (sdrController?.activeChannelCount ?? 1)
            : demodulatedChannelCount(modulation: f.modulation, stereoFlag: f.stereoFlag, sampleRate: f.sampleRate)

        s += "<br><br>frequency: \(htmlText(f.formattedFrequency))<br>"
        s += "modulation: \(htmlText(modulation))<br>"
        s += "sample rate: \(f.sampleRate)<br>"
        s += "device: \(htmlText(deviceLabel))<br>"
        s += "gain: \(htmlText(gainLabel(gain: f.tunerGain, agc: f.tunerAgc == 1)))<br>"
        s += "channels: \(htmlText(channelsLabel(channels)))<br><br>"
        return (f.stationName, s)
    }

    /// `%%EDIT_FAVORITE_NAME%%` + `%%EDIT_FAVORITE%%` — the favorite edit form.
    /// Field `name`s match the `frequency` table columns and the client-side
    /// validator in `antennahead.js`; Save posts to `storefrequency.html` and
    /// Delete to `deletefrequency.html` (both handled by `appStateResponse`).
    @MainActor private func editFavorite(id: Int64) -> (name: String, item: String) {
        guard let f = (try? sqlite?.frequencyRecord(forID: id)) ?? nil else {
            return ("", "Error getting favorite id = \(id)")
        }

        func text(_ label: String, _ name: String, _ value: String, id elementID: String? = nil,
                  type: String = "text", step: String? = nil, list: String? = nil) -> String {
            let idAttr = elementID.map { " id='\($0)'" } ?? ""
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            let listAttr = list.map { " list='\($0)'" } ?? ""
            return "<label>\(label)<input class='u-full-width' type='\(type)'\(idAttr) \(Self.verbatimInputAttributes) "
                + "name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)\(listAttr)></label>"
        }
        func select(_ label: String, _ name: String, _ current: String, _ options: [(value: String, label: String)]) -> String {
            var s = "<label>\(label)<select class='u-full-width' name='\(name)'>"
            for opt in options {
                let selected = opt.value == current ? " selected" : ""
                s += "<option value='\(htmlAttribute(opt.value))'\(selected)>\(htmlText(opt.label))</option>"
            }
            s += "</select></label>"
            return s
        }

        let modulationOptions = Frequency.modulationOptions.map { ($0, $0.uppercased()) }

        var s = "<form id='editFrequencyForm' onsubmit=\"event.preventDefault(); return storeFrequencyRecord(this);\" method='POST'>"
        s += "<input type='hidden' name='id' value='\(id)'>"
        s += text("Station Name", "station_name", f.stationName, id: "frequency_name")
        s += text("Frequency (Hz)", "frequency", "\(f.frequency)", type: "number")
        s += select("Frequency Mode", "frequency_mode", f.frequencyMode == 1 ? "frequency_mode_range" : "frequency_mode_single",
                    [("frequency_mode_single", "Single Frequency"), ("frequency_mode_range", "Scan Range")])
        s += text("Scan Range End (Hz)", "frequency_scan_end", "\(f.frequencyScanEnd)", type: "number")
        s += text("Scan Range Interval (Hz)", "frequency_scan_interval", "\(f.frequencyScanInterval)", type: "number")
        s += select("Modulation", "modulation", f.modulation, modulationOptions)
        s += select("FM Stereo", "stereo_flag", f.stereoFlag ? "1" : "0", [("0", "Off"), ("1", "On")])
        s += text("Sample Rate", "sample_rate", "\(f.sampleRate)", type: "number")
        s += text("Tuner Gain", "tuner_gain", "\(f.tunerGain)", type: "number", step: "0.1")
        s += select("Tuner AGC", "tuner_agc", "\(f.tunerAgc)", [("0", "Off"), ("1", "On")])
        s += select("Sampling Mode", "sampling_mode", "\(f.samplingMode)",
                    [("0", "Standard"), ("1", "Direct Sampling (I)"), ("2", "Direct Sampling (Q)")])
        s += text("Oversampling", "oversampling", "\(f.oversampling)", type: "number")
        s += text("Squelch Level", "squelch_level", "\(f.squelchLevel)", type: "number", step: "0.1")
        s += text("FIR Size", "fir_size", "\(f.firSize)", type: "number")
        s += text("Atan Math", "atan_math", f.atanMath)
        s += text("Audio Output Filter", "audio_output_filter", f.audioOutputFilter)
        s += text("rtl_fm Options", "options", f.options)
        s += text("USB Device (serial number or index)", "usb_device_string", formattedUSBDeviceValue(f.usbDeviceString), list: "usb_device_datalist")
        s += "<datalist id='usb_device_datalist'></datalist>"
        s += select("Bias-T Power", "bias_t_flag", "\(f.biasTFlag)", [("0", "Off"), ("1", "On")])
        s += "<br><br>"
        s += "<input class='button button-primary' type='submit' value='Save'>"
        s += " <input class='button' type='button' value='Delete' onclick='deleteFrequencyRecord(this.form);'>"
        s += "</form>"
        return (f.stationName, s)
    }

    /// Applies a posted edit form to the matching `frequency` record. Unlisted
    /// fields keep their stored values (the form is loaded from the same record).
    @MainActor private func saveFrequency(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        guard let idString = fields["id"], let id = Int64(idString),
              var record = (try? sqlite?.frequencyRecord(forID: id)) ?? nil else { return }

        if let v = fields["station_name"] { record.stationName = v }
        if let v = fields["frequency"], let n = Int(v) { record.frequency = n }
        if let v = fields["frequency_mode"] { record.frequencyMode = (v == "frequency_mode_range") ? 1 : 0 }
        if let v = fields["frequency_scan_end"], let n = Int(v) { record.frequencyScanEnd = n }
        if let v = fields["frequency_scan_interval"], let n = Int(v) { record.frequencyScanInterval = n }
        if let v = fields["modulation"] { record.modulation = v }
        if let v = fields["stereo_flag"] { record.stereoFlag = (v == "1") }
        if let v = fields["sample_rate"], let n = Int(v) { record.sampleRate = n }
        if let v = fields["tuner_gain"], let n = Double(v) { record.tunerGain = n }
        if let v = fields["tuner_agc"], let n = Int(v) { record.tunerAgc = n }
        if let v = fields["sampling_mode"], let n = Int(v) { record.samplingMode = n }
        if let v = fields["oversampling"], let n = Int(v) { record.oversampling = n }
        if let v = fields["squelch_level"], let n = Double(v) { record.squelchLevel = n }
        if let v = fields["fir_size"], let n = Int(v) { record.firSize = n }
        if let v = fields["atan_math"] { record.atanMath = v }
        if let v = fields["audio_output_filter"] { record.audioOutputFilter = v }
        if let v = fields["options"] { record.options = v }
        if let v = fields["usb_device_string"] { record.usbDeviceString = v }
        if let v = fields["bias_t_flag"], let n = Int(v) { record.biasTFlag = n }

        try? sqlite?.updateFrequencyRecord(record)
    }

    /// Deletes the `frequency` record identified by the posted form's `id`.
    @MainActor private func deleteFrequency(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        if let idString = fields["id"], let id = Int64(idString) {
            try? sqlite?.deleteFrequencyRecord(forID: id)
        }
    }

    // MARK: Now Playing

    /// Button rendered into `%%OPEN_AUDIO_PLAYER_PAGE_BUTTON%%`. Starts the
    /// persistent audio element in the top frame via the same `postMessage`
    /// signal the Listen buttons use.
    nonisolated static let openAudioPlayerButtonHTML =
        "<input class='button button-primary' type='button' value='&#9654; Open Audio Player' "
        + "onclick=\"window.top.postMessage('startaudio', '*');\">"

    /// The active favorite's full record, when tuned to a single frequency.
    @MainActor private func activeFrequencyRecord() -> Frequency? {
        guard let id = sdrController?.activeFrequencyID else { return nil }
        return (try? sqlite?.frequencyRecord(forID: id)) ?? nil
    }

    /// `%%NOW_PLAYING_NAME%%` + `%%NOW_PLAYING_DETAILS%%` for the initial page
    /// render. The page's JS then refreshes these live from `nowplayingstatus.html`.
    @MainActor private func nowPlayingPage() -> (name: String, details: String) {
        guard let sdr = sdrController, sdr.taskMode != .stopped else {
            return ("Radio is stopped", "<br><br>No active tuning.")
        }
        guard let f = activeFrequencyRecord() else {
            let name = sdr.stationName.isEmpty ? sdr.statusFunction : sdr.stationName
            return (name, "<br><br>" + htmlText(sdr.statusFunction))
        }

        func row(_ label: String, _ value: String) -> String { "\(label): \(htmlText(value))<br>" }
        var d = "<br><br>"
        d += row("frequency", f.formattedFrequency)
        d += row("signal level", "\(sdr.signalLevel)")
        d += row("squelch level", "\(f.squelchLevel)")
        d += row("modulation", f.modulation)
        d += row("sample rate", "\(f.sampleRate)")
        d += row("channels", channelsLabel(sdr.activeChannelCount))
        d += row("sampling mode", "\(f.samplingMode)")
        d += row("oversampling", "\(f.oversampling)")
        d += row("tuner gain", gainLabel(gain: f.tunerGain, agc: f.tunerAgc == 1))
        d += row("tuner agc", "\(f.tunerAgc)")
        d += row("rtl-sdr options", "pad \(f.options)")
        d += row("fir size", "\(f.firSize)")
        d += row("atan math", f.atanMath)
        d += row("audio output filter", "rate 48000 \(f.audioOutputFilter)")
        d += row("bias-t", "\(f.biasTFlag)")
        d += row("device", activeDeviceLabel(stored: f.usbDeviceString))
        return (f.stationName, d)
    }

    /// JSON consumed by `nowplaying.html`'s `updateStatusDisplay()` for live
    /// refresh. Keys match the fields that JS reads (`rtlsdr_task_mode`,
    /// `station_name`, `short_frequency`, the `frequency` columns, …).
    @MainActor private func nowPlayingStatusJSON() -> Data {
        var dict: [String: Any] = [
            "rtlsdr_task_mode": sdrController?.taskMode.rawValue ?? "stopped",
            "signal_level": sdrController?.signalLevel ?? 0
        ]
        if let f = activeFrequencyRecord() {
            dict["station_name"] = f.stationName
            dict["short_frequency"] = f.formattedFrequency
            dict["frequency"] = f.frequency
            dict["frequency_mode"] = f.frequencyMode
            dict["frequency_scan_end"] = f.frequencyScanEnd
            dict["frequency_scan_interval"] = f.frequencyScanInterval
            dict["modulation"] = f.modulation
            dict["sample_rate"] = f.sampleRate
            dict["sampling_mode"] = f.samplingMode
            dict["oversampling"] = f.oversampling
            dict["tuner_gain"] = f.tunerGain
            dict["tuner_agc"] = f.tunerAgc
            dict["squelch_level"] = f.squelchLevel
            dict["fir_size"] = f.firSize
            dict["atan_math"] = f.atanMath
            dict["audio_output_filter"] = f.audioOutputFilter
            dict["options"] = f.options
            dict["bias_t_flag"] = f.biasTFlag
            dict["usb_device_string"] = f.usbDeviceString
            dict["usb_device_display"] = activeDeviceLabel(stored: f.usbDeviceString)
            dict["tuner_gain_display"] = gainLabel(gain: f.tunerGain, agc: f.tunerAgc == 1)
            let channelCount = sdrController?.activeChannelCount ?? 0
            dict["channels"] = channelCount
            dict["channels_display"] = channelsLabel(channelCount)
            dict["stereo_flag"] = f.stereoFlag ? 1 : 0
        } else {
            dict["station_name"] = sdrController?.statusFunction ?? "Not Playing"
            dict["short_frequency"] = ""
        }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    /// Live speech-to-text state for a polling caption client: whether the
    /// `PCMTranscriber` tap is enabled, the current volatile hypothesis, and
    /// the finalized transcript so far (oldest first). Empty/blank when
    /// transcription is off or nothing has been recognized yet.
    @MainActor private func captionsJSON() -> Data {
        let dict: [String: Any] = [
            "enabled": sdrController?.transcriptionEnabled ?? false,
            "live": sdrController?.liveCaption ?? "",
            "final": sdrController?.captionHistory ?? [],
            "seq": sdrController?.captionSeq ?? 0
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Parses a jQuery `serializeArray()` body — `[{"name":..,"value":..}, ...]`
    /// — into a `[name: value]` dictionary.
    nonisolated private func formFields(fromBody body: Data) -> [String: String] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let array = object as? [[String: Any]] else { return [:] }
        var fields: [String: String] = [:]
        for field in array {
            guard let name = field["name"] as? String else { continue }
            if let value = field["value"] as? String {
                fields[name] = value
            } else if let number = field["value"] as? NSNumber {
                fields[name] = number.stringValue
            }
        }
        return fields
    }

    /// Parses a JSON *object* body into `[String: Any]` (the Tuner's Listen
    /// button posts an object, not the serializeArray array).
    nonisolated private func jsonObject(fromBody body: Data) -> [String: Any] {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    nonisolated private func okResponse() -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK",
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data("OK".utf8))
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

    /// Zero-pads an all-digit value shorter than 8 digits to the standard
    /// 8-digit RTL-SDR EEPROM serial format, e.g. "1234" -> "00001234".
    /// Non-numeric or already-8-digit-or-longer values pass through unchanged.
    nonisolated private func zeroPadded8DigitSerial(_ value: String) -> String {
        guard !value.isEmpty, value.count < 8, value.allSatisfy(\.isNumber) else {
            return value
        }
        return String(repeating: "0", count: 8 - value.count) + value
    }

    /// Formats a "USB Device" field value for display. A bare single digit
    /// ("0"-"9") is a USB device index and is left as-is; anything else that's
    /// all digits is assumed to be an RTL-SDR EEPROM serial number (see
    /// rtl_eeprom) and is zero-padded via `zeroPadded8DigitSerial`.
    nonisolated private func formattedUSBDeviceValue(_ value: String) -> String {
        guard value.count > 1 else {
            return value
        }
        return zeroPadded8DigitSerial(value)
    }

    /// One entry in the "USB Device" combo box's `<datalist>` — see
    /// `usbDeviceOptionsJSON`.
    private struct USBDeviceOption: Encodable {
        /// What gets written into the USB Device field when this option is
        /// picked: the device's zero-padded serial if it has one, else its
        /// USB device index.
        let value: String
        /// Human-readable text shown in the dropdown alongside `value`.
        let label: String
    }

    /// JSON body for `/rtlsdrdevices.html`: the currently connected RTL-SDR
    /// devices, one `USBDeviceOption` each, for the web UI's USB Device
    /// combo box. `devices` should come from `RTLSDRDeviceList.enumerate()`
    /// run off the main actor (see that call site) since it blocks briefly
    /// on libusb enumeration.
    nonisolated private func usbDeviceOptionsJSON(devices: [RTLSDRDevice]) -> Data {
        let options: [USBDeviceOption] = devices.map { device in
            let serial = zeroPadded8DigitSerial(device.serial)
            let productLabel = device.product.isEmpty ? device.name : device.product
            if serial.isEmpty {
                return USBDeviceOption(value: "\(device.index)", label: "Index \(device.index) — \(productLabel)")
            }
            return USBDeviceOption(value: serial, label: "\(serial) — \(productLabel) (index \(device.index))")
        }
        return (try? JSONEncoder().encode(options)) ?? Data("[]".utf8)
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
            // Safety net so `%%THEME%%` is never left raw on this nonisolated
            // path; the `/` and `/index.html` routes override it via `extra`
            // with the stored value (see `appStateResponse`). Literal rather
            // than `Self.defaultWebUITheme` to stay off the MainActor here.
            dict["THEME"]        = "auto"
        case "index2.html":
            func col(_ svg: String, onclick: String, title: String, label: String, description: String) -> String {
                """
                        <div class="six columns value-prop">
                            \(svg)
                            <div class="value-prop">
                                <a class="button button-primary" onclick="loadContent('\(onclick)')" title="\(title)">\(label)</a>
                            </div>
                            \(description)
                        </div>
                """
            }
            var items: [String] = [
                col(loadSVG(named: "radio"),       onclick: "radio.html",      title: "Click the Radio button to listen to RTL-SDR radio via your Favorites, Categories, and the Tuner.",                              label: "Radio",       description: "Listen to RTL-SDR radio"),
                col(loadSVG(named: "recordings"),  onclick: "recordings.html", title: "Click the Recordings button to play back a recorded audio file.",                                                                    label: "Recordings",  description: "Browse and listen to recorded files."),
                col(loadSVG(named: "devices"),     onclick: "devices.html",    title: "Stream audio from a device connected to the Mac audio input jack or Core Audio.",                                                    label: "Devices",     description: "Audio input, Gqrx, or text to speech."),
            ]
            items.append(contentsOf: [
                col(loadSVG(named: "gear"),  onclick: "settings.html", title: "Click the Settings button to set the AAC streaming rate, and restart the streaming servers.", label: "Settings", description: "Streaming settings and app info."),
                col(loadSVG(named: "info"),  onclick: "info.html",     title: "More information about AntennaHead.",                                                           label: "Info",     description: "About AntennaHead."),
            ])
            var rows = ""
            var i = 0
            while i < items.count {
                rows += "<div class=\"value-prop row\">\n"
                rows += items[i]
                if i + 1 < items.count { rows += "\n" + items[i + 1] }
                rows += "\n</div>\n"
                i += 2
            }
            dict["MENU_ROWS"] = rows
        case "radio.html":
            // Same icons the top-level menu used for these items before they
            // were folded behind the single "Radio" entry.
            dict["FAVORITES_ICON"]  = loadSVG(named: "favorites")
            dict["CATEGORIES_ICON"] = loadSVG(named: "categories")
            dict["TUNER_ICON"]      = loadSVG(named: "tuner")
        case "info.html":
            dict["LOCALRADIO_ANIMATION"] = loadSVG(named: "AntennaHead-animation")
        case "devices.html":
            // Tile icons, in the same inlined-SVG style as the top-level menu.
            // "Select Audio Input" and "ControlBooth" reuse the icons those
            // items carried when they lived on the top-level hub; Gqrx and
            // Text-to-Speech get their own matching line-art icons.
            dict["AUDIO_INPUT_ICON"]     = loadSVG(named: "devices")
            dict["GQRX_ICON"]            = loadSVG(named: "gqrx")
            dict["TEXT_TO_SPEECH_ICON"]  = loadSVG(named: "texttospeech")
            // The ControlBooth remote-control page is reached from a tile on the
            // Devices page (it used to be a top-level hub item). The tile only
            // appears when ControlBooth integration is enabled in Configuration,
            // mirroring the old hub gate.
            dict["CONTROLBOOTH_TILE"] = webConfig.controlBoothEnabled ? """
                            <div class="six columns value-prop">
                                \(loadSVG(named: "controlbooth"))
                                <div class="value-prop">
                                    <a class="button button-primary" onclick="loadContent('controlbooth.html');">ControlBooth</a>
                                </div>
                                Start a ControlBooth pipeline<br>as the audio source
                            </div>
                """ : ""
        default:
            break
        }
        return dict
    }

    // MARK: %%NAV_BAR%% and %%AUDIO_PLAYER%% (ported from LocalRadio's HTTPWebServerConnection)

    /// Static top navigation bar (Back / Top / Captions / Now Playing). The
    /// referenced JS functions live in `index.html`.
    nonisolated private func navBarHTML() -> String {
        """
           <div class="navbar-spacer"></div>
           <nav class="navbar">
              <div class="container">
                <ul class="navbar-list">
                  <li class="navbar-item"><a class="navbar-link" href="#" onclick="backButtonClicked(self);" title="Click the Back button to return to the previous page in the web interface">Back</a></li>
                  <li class="navbar-item"><a class="navbar-link" href="#" onclick="loadContent('index2.html');" title="Click the Top button to reload the web interface.">Top</a></li>
                  <li class="navbar-item"><a class="navbar-link" id="captionsNavBarLink" href="#" onclick="loadContent('captions.html');" title="Click the Captions button to see live speech-to-text of the audio that is currently streaming.">Captions</a></li>
                  <li class="navbar-item"><a class="navbar-link" id="nowPlayingNavBarLink" href="#" onclick="loadContent('nowplaying.html');" title="Click the Now Playing button to see the current activity on the radio, including the live Signal Level.">Now Playing</a></li>
                </ul>
              </div>
            </nav>
        """
    }

    /// `<audio>` element pointing at LiveAudioServer's live HLS playlist,
    /// proxied through *this* server rather than LAS's own port (see
    /// `proxyToLiveAudioServer` and `WebConfig.selfHTTPPort`) so a browser
    /// only has to authenticate once. Uses the same hostname the client used
    /// to reach this page, so it resolves from phones on the LAN.
    nonisolated private func audioPlayerHTML(host: String, isSecure: Bool, webConfig: WebConfig) -> String {
        let scheme = isSecure ? "https" : "http"
        let port = isSecure ? (webConfig.selfHTTPSPort ?? webConfig.selfHTTPPort) : webConfig.selfHTTPPort
        // AntennaHead's own embedded WKWebView tabs load this page via
        // http://localhost, so `host` here is literally "localhost". That's
        // fine for playback relayed locally (HomePod/AirPlay 1), but AirPlay 2
        // receivers that support "buffered" playback (e.g. Apple TV) can fetch
        // the stream URL themselves instead — and "localhost" on that device
        // means itself, not this Mac. Substitute a LAN-reachable host so the
        // stream is actually fetchable by a different device.
        let audioHost = HostInfo.isLoopback(host) ? HostInfo.shareableHost() : host
        let src = "\(scheme)://\(audioHost):\(port)\(webConfig.hlsMount)"
        let mimeType = "application/vnd.apple.mpegurl"
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
        let audioTag = "<audio id='audio_element' controls \(autoplay)preload=\"none\" src='\(src)' type='\(mimeType)'\(handlers)>Your browser does not support the audio element.</audio>"
        return aacRecorderToggleHTML() + audioTag
    }

    /// Compact record/stop toggle for the AAC stream, shown next to the
    /// `<audio>` element. Talks to this server's own `/api/aac-recorder/*`
    /// routes (see `startAACRecording()`/`aacRecorderStatusResponse()`), which
    /// in turn drive `LiveAudioServerProcessManager.startRecording(at:)` —
    /// *not* LAS's raw recorder API directly, since that helper already
    /// handles the App Sandbox temp-file dance and the move into the shared
    /// App Group Recordings folder (see its doc comment). JS lives in
    /// `js/antennahead.js` (`aacRecorderToggle()` and friends).
    nonisolated private func aacRecorderToggleHTML() -> String {
        """
        <span id="aac-recorder-toggle" class="aac-recorder-toggle">
          <button type="button" id="aac-rec-btn" class="rec-btn" onclick="aacRecorderToggle();" title="Click to start/stop audio recording">⏺</button>
          <span id="aac-rec-time" class="rec-time" style="display:none">00:00</span>
        </span>
        """
    }

    // Tokens shared across every dynamic page. Extend as pages migrate from
    // LocalRadio (e.g. NAV_BAR, COMPUTER_NAME, device-health messages).
    nonisolated private func globalReplacements() -> [String: String] {
        ["ERROR_MESSAGE": "", "ASSET_VERSION": Self.assetCacheToken]
    }

    /// Cache-busting token appended to versioned Web asset URLs (see
    /// `?v=%%ASSET_VERSION%%` in `Web/index.html`). Ties each `css/*.css` /
    /// `js/*.js` cache key to this build so mobile Safari — which caches those
    /// hard and ignores the HTML's no-cache meta — reloads a rebuilt asset
    /// instead of serving a stale copy. Derived from the app executable's
    /// modification time (bumps on every rebuild); falls back to the launch
    /// time if that can't be read. The `?v=` query is stripped before the
    /// static-file lookup (`pathWithoutQuery`), so it only affects the browser.
    nonisolated static let assetCacheToken: String = {
        if let exe = Bundle.main.executableURL,
           let modified = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date {
            return String(Int(modified.timeIntervalSince1970))
        }
        return String(Int(Date().timeIntervalSince1970))
    }()

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

    /// Fast-download playback route (`/recordings-download/<filename>`): serves
    /// a recording straight from the shared Recordings folder as a plain,
    /// Range-capable file — unlike `Listen`, which feeds the file through
    /// `PCMFilePlayer` into the live HLS stream (see `SDRController.
    /// startTasksForRecording`). Pointing the `<audio>` element's `src`
    /// directly at this route (see `recordingDownloadButtonClicked` in
    /// antennahead.js) is what lets the browser's native seek bar work — HLS
    /// live playlists don't expose a seekable timeline, but a Range-capable
    /// static file does. `fileName` is resolved against the Recordings folder
    /// only (no path separators allowed), same guard as
    /// `SDRController.startTasksForRecording`, so a tampered request can't
    /// reach outside that folder.
    nonisolated private func recordingDownloadResponse(path: String, request: HTTPRequest) -> HTTPResponse {
        let encodedName = String(path.dropFirst(Self.recordingsDownloadPrefix.count))
        guard let fileName = encodedName.removingPercentEncoding,
              !fileName.isEmpty, !fileName.contains("/") else {
            return .notFound
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard Self.recordingsFileExtensions.contains(ext),
              let folder = SharedRecordingFolder.url else {
            return .notFound
        }
        let originalURL = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return .notFound
        }

        // Raw ADTS AAC (.aac) has no container-level duration field, so
        // browsers estimate it by sampling the bitrate of the first few
        // frames and extrapolating across the file's byte size. A recording
        // that opens with LiveAudioServer's silence filler (a few seconds of
        // dead air before a scheduled ControlBooth recording's tuner locks
        // on) starts with abnormally tiny frames, which throws that estimate
        // off by 20-30x -- a 60-minute recording reporting a ~26-hour
        // duration, which then corrupts the <audio> element's seek bar and
        // playback position bookkeeping. Serving a losslessly remuxed .m4a
        // instead sidesteps the whole problem: MPEG-4 containers carry a
        // real duration box, so no estimation is needed. Falls back to the
        // raw file if remuxing fails for any reason.
        var fileURL = originalURL
        var servedExt = ext
        if ext == "aac", let m4aURL = remuxedM4A(forRecordingAt: originalURL) {
            fileURL = m4aURL
            servedExt = "m4a"
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let total = attrs[.size] as? Int else {
            return .notFound
        }
        let contentType = mimeType(forExtension: servedExt)

        // No Range header (or an unparseable one): serve the whole file, same
        // as staticFile(). This is the request the browser makes first, before
        // it knows the resource is seekable.
        guard let rangeHeader = request.headers["range"],
              let (start, rawEnd) = Self.parseByteRange(rangeHeader), start >= 0 else {
            guard let data = try? Data(contentsOf: fileURL) else { return .notFound }
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": contentType, "Accept-Ranges": "bytes"],
                                body: data)
        }
        let end = min(rawEnd, total - 1)
        guard total > 0, start < total, start <= end else {
            return HTTPResponse(status: 416, reason: "Range Not Satisfiable",
                                headers: ["Content-Range": "bytes */\(total)"],
                                body: Data())
        }
        // Seeking sends many small ranged requests, so read only the
        // requested slice rather than the whole file each time (unlike the
        // no-Range branch above, where the whole file is wanted anyway).
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .notFound }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            let slice = try handle.read(upToCount: end - start + 1) ?? Data()
            return HTTPResponse(status: 206, reason: "Partial Content",
                                headers: ["Content-Type": contentType, "Accept-Ranges": "bytes",
                                          "Content-Range": "bytes \(start)-\(end)/\(total)"],
                                body: slice)
        } catch {
            return .notFound
        }
    }

    /// Returns a losslessly-remuxed `.m4a` copy of `fileURL` (a raw `.aac`
    /// recording), cached in `recordingsDownloadCacheFolder` keyed by the
    /// source's mtime+size so this only runs once per recording — subsequent
    /// requests (including every ranged seek request during playback) just
    /// reuse the cached file. `nil` if remuxing fails for any reason, in
    /// which case `recordingDownloadResponse` falls back to serving the raw
    /// `.aac` (the pre-existing behavior, with its duration-estimate quirk).
    nonisolated private func remuxedM4A(forRecordingAt fileURL: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date,
              let cacheFolder = Self.recordingsDownloadCacheFolder else {
            return nil
        }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let cacheURL = cacheFolder.appendingPathComponent("\(stem)-\(Int(mtime.timeIntervalSince1970))-\(size).m4a")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        // Remux into a uniquely-named temp file first, then move into place —
        // avoids two near-simultaneous Download & Play requests for the same
        // uncached recording colliding on the same output path mid-write.
        let tempURL = cacheFolder.appendingPathComponent(".\(stem)-\(UUID().uuidString).m4a.tmp")
        guard remux(from: fileURL, to: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            try? FileManager.default.moveItem(at: tempURL, to: cacheURL)
        }
        try? FileManager.default.removeItem(at: tempURL) // no-op if the move above succeeded
        return FileManager.default.fileExists(atPath: cacheURL.path) ? cacheURL : nil
    }

    /// Reads `sourceURL`'s single audio track via `AVAssetReader` and
    /// rewrites it to `destinationURL` as an `.m4a` via `AVAssetWriter`,
    /// passing the original compressed AAC samples through unchanged (`nil`
    /// output settings = passthrough: repackaging, not decoding/re-encoding —
    /// fast, and lossless). Blocks the calling thread for the duration
    /// (there's no synchronous `AVAssetWriter.finishWriting`), consistent
    /// with the rest of this server's fully-buffered, single-shot response
    /// model — see `proxyToLiveAudioServer`'s doc comment for that constraint.
    nonisolated private func remux(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let asset = AVURLAsset(url: sourceURL)

        // `loadTracks(withMediaType:)` is async-only; bridge it to this
        // function's synchronous, blocks-the-calling-thread model (see the
        // doc comment above) the same way `writer.finishWriting` is bridged
        // further down, via a semaphore.
        var loadedTracks: [AVAssetTrack] = []
        var loadedFormatDescriptions: [CMFormatDescription] = []
        let trackLoadSemaphore = DispatchSemaphore(value: 0)
        Task {
            loadedTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if let track = loadedTracks.first {
                loadedFormatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
            }
            trackLoadSemaphore.signal()
        }
        trackLoadSemaphore.wait()

        guard let track = loadedTracks.first,
              let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: destinationURL, fileType: .m4a) else {
            return false
        }

        // Decode to LPCM and re-encode to AAC, rather than passing the raw
        // ADTS samples through unchanged: passthrough (nil output settings)
        // reliably failed to mux this app's ADTS AAC into an MP4 container
        // (AVAssetWriterInput.append() erroring a couple of samples in, right
        // where LiveAudioServer's tiny silence-filler frames are) — most
        // likely because a bare ADTS format description doesn't carry what
        // MP4 muxing needs to build a proper `esds`/AudioSpecificConfig box.
        // Decode+re-encode sidesteps that: the writer builds its own
        // well-formed AAC configuration from scratch. The extra CPU cost is
        // one-time and cached (see remuxedM4A) and still much faster than
        // realtime on any Mac this app runs on.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        guard let formatDescription = loadedFormatDescriptions.first else {
            return false
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let encodeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encodeSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        guard reader.startReading() else {
            let message = "Remux to M4A: AVAssetReader.startReading failed for \(sourceURL.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")"
            Task { @MainActor in LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", message) }
            return false
        }
        guard writer.startWriting() else {
            let message = "Remux to M4A: AVAssetWriter.startWriting failed for \(sourceURL.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")"
            Task { @MainActor in LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", message) }
            return false
        }
        writer.startSession(atSourceTime: .zero)

        var appendedCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !input.append(sampleBuffer) {
                let message = "Remux to M4A: append failed after \(appendedCount) samples for \(sourceURL.lastPathComponent): writerStatus=\(writer.status.rawValue) \(writer.error?.localizedDescription ?? "no error set")"
                Task { @MainActor in LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", message) }
                break
            }
            appendedCount += 1
        }
        input.markAsFinished()

        guard reader.status == .completed else {
            let message = "Remux to M4A: reader ended in status=\(reader.status.rawValue) after \(appendedCount) samples for \(sourceURL.lastPathComponent): \(reader.error?.localizedDescription ?? "no error set")"
            Task { @MainActor in LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", message) }
            writer.cancelWriting()
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status != .completed {
            let nsError = writer.error as NSError?
            let message = "Remux to M4A failed for \(sourceURL.lastPathComponent): status=\(writer.status.rawValue) " +
                "domain=\(nsError?.domain ?? "?") code=\(nsError?.code ?? 0) " +
                "desc=\(nsError?.localizedDescription ?? "?") underlying=\(String(describing: nsError?.userInfo[NSUnderlyingErrorKey]))"
            Task { @MainActor in LogStore.shared.log(.error, source: "AntennaHeadHTTPServer", message) }
        }
        return writer.status == .completed
    }

    /// Parses a single-range `Range: bytes=start-end` header (the only form
    /// browsers send for `<audio>` seeking) into a raw `(start, end)` pair —
    /// `end` is `Int.max` when omitted (`bytes=1000-` means "to EOF"), left
    /// for the caller to clamp against the file size and turn into a 416 if
    /// unsatisfiable. `nil` for anything malformed or multi-range, which
    /// callers treat as "serve the whole file" — the safe fallback.
    nonisolated private static func parseByteRange(_ header: String) -> (Int, Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil } // multi-range: not supported, fall back to whole file
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? Int.max : (Int(parts[1]) ?? Int.max)
        return (start, end)
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
        case "aac": return "audio/aac"
        case "m4a": return "audio/mp4"
        case "caf": return "audio/x-caf" // not browser-playable; recordingDownloadButtonClicked() excludes it
        default: return "application/octet-stream"
        }
    }
}
