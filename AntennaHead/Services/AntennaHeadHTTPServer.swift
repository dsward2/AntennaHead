import Foundation
import Network

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

    /// Retained for compatibility with code that reads `httpServer.port`.
    var port: UInt16 { httpPort }

    /// Posted after the web Settings page stores a new value. ContentView
    /// observes this and restarts services so the change takes effect (the
    /// output bitrate is baked into both `WebConfig` and the LAS launch args).
    static let settingsDidChangeNotification = Notification.Name("AntennaHeadHTTPServer.settingsDidChange")

    /// `local_radio_config` key holding the system-wide stream output bitrate
    /// in bits/sec (key name retained from LocalRadio's database).
    static let outputBitrateConfigKey = "AACBitrate"
    static let defaultOutputBitrate = 128_000
    static let outputBitrateOptions = [32_000, 48_000, 64_000, 96_000, 128_000, 192_000, 256_000]

    /// The stored output bitrate (bits/sec), falling back to the default.
    @MainActor static func storedOutputBitrate(sqlite: SQLiteController?) -> Int {
        let stored = ((try? sqlite?.localRadioAppSettingsValue(forKey: outputBitrateConfigKey)) ?? nil)
            .flatMap(Int.init)
        guard let stored, outputBitrateOptions.contains(stored) else { return defaultOutputBitrate }
        return stored
    }

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
        // Advertise the web UI on the LAN via Bonjour (visible in Safari's
        // Bonjour bookmarks and discovery apps).
        listener.service = NWListener.Service(name: "AntennaHead",
                                              type: isSecure ? "_https._tcp" : "_http._tcp")
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

        case "/devices.html":
            return renderHTML(relativePath: "devices.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["DEVICES_FORM": devicesFormHTML(),
                                      "CUSTOM_TASKS_FORM": customTasksFormHTML()])

        case "/devicelistenbuttonclicked.html":
            // Buttons are wired; the Core Audio device-input pipeline is deferred
            // (needs a capture helper), so this currently logs .notImplemented.
            let fields = formFields(fromBody: request.body)
            sdrController?.startTasksForDevice(deviceName: fields["audio_input"] ?? "",
                                               deviceAudioOutputFilter: fields["audio_output_filter"] ?? "vol 1")
            return okResponse()

        case "/customtasklistenbuttonclicked.html":
            if let id = formFields(fromBody: request.body)["custom_task_select"].flatMap(Int64.init) {
                try? sdrController?.startTasksForCustomTask(id: id)
            }
            return okResponse()

        case "/settings.html":
            return renderHTML(relativePath: "settings.html", host: host, isSecure: isSecure, webConfig: webConfig,
                              extra: ["AAC_BITRATE_SELECT": outputBitrateSelectOptionsHTML()])

        case "/applyaacsettings.html":
            // POST body is a JSON object {bitrate: "<bps>"} from applyAACSettings().
            let bitrate = Int(jsonObject(fromBody: request.body).string("bitrate"))
            if let bitrate, Self.outputBitrateOptions.contains(bitrate) {
                try? sqlite?.storeLocalRadioAppSettingsValue("\(bitrate)", forKey: Self.outputBitrateConfigKey)
                NotificationCenter.default.post(name: Self.settingsDidChangeNotification, object: nil)
            }
            return okResponse()

        case "/customtasks.html":
            return htmlFragmentResponse(customTasksManagerHTML())

        case "/editcustomtask.html":
            let id = queryValue("id", in: request.path).flatMap(Int64.init)
            return htmlFragmentResponse(editCustomTaskHTML(id: id))

        case "/storecustomtask.html":
            upsertCustomTask(fromBody: request.body)
            return okResponse()

        case "/deletecustomtask.html":
            if let id = formFields(fromBody: request.body)["id"].flatMap(Int64.init) {
                try? sqlite?.deleteCustomTaskRecord(forID: id)
            }
            return okResponse()

        case "/frequencylistenbuttonclicked.html":
            // Ad-hoc tune from the web Tuner. Body is a JSON *object*
            // {frequency, sample_rate, tuner_gain, stereo_flag, modulation}.
            let o = jsonObject(fromBody: request.body)
            if let hz = Int(o.string("frequency")), hz > 0 {
                sdrController?.startTasksForFrequency(
                    frequencyHz: hz,
                    sampleRate: Int(o.string("sample_rate")) ?? 170_000,
                    tunerGain: Double(o.string("tuner_gain")) ?? 49.6,
                    stereo: o.string("stereo_flag") == "1",
                    modulation: o.string("modulation"))
            }
            return okResponse()

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
    /// with the stored `local_radio_config` value selected.
    @MainActor private func outputBitrateSelectOptionsHTML() -> String {
        let current = Self.storedOutputBitrate(sqlite: sqlite)
        var s = ""
        for bps in Self.outputBitrateOptions {
            s += "<option value='\(bps)'\(bps == current ? " selected" : "")>\(bps / 1000) kbps</option>"
        }
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

    /// `%%CUSTOM_TASKS_FORM%%` — dropdown of saved custom tasks + Listen.
    /// Ported from `generateCustomTasksFormString`.
    @MainActor private func customTasksFormHTML() -> String {
        let tasks = (try? sqlite?.allCustomTaskRecords()) ?? []
        var s = "<form class='custom_task_form' id='customTaskForm' onsubmit='event.preventDefault(); return false;' method='POST'>"
        s += "<label for='custom_task_select'>Select Custom Task</label>"
        s += "<select name='custom_task_select' class='twelve columns value-prop' title='Uses an external task pipeline as the audio source.'>"
        for t in tasks {
            guard let id = t.id else { continue }
            s += "<option value='\(id)'>\(htmlText(t.taskName))</option>"
        }
        s += "</select>"
        s += "<br><br><input class='twelve columns button button-primary' type='button' value='Listen' "
        s += "onclick=\"customTaskListenButtonClicked(getElementById('customTaskForm'));\" "
        s += "title='Listen to the selected custom task.'>"
        s += "</form>"
        s += "<form action='javascript:loadContent(&quot;customtasks.html&quot;)'>"
        s += "<input class='twelve columns button' type='submit' value='Manage Custom Tasks'></form><br>&nbsp;<br>"
        return s
    }

    // MARK: Custom-task web manager (list / edit / upsert / delete)

    /// Fragment returned for pages that have no `%%…%%` template file. Loaded
    /// into index.html's content_frame by `loadContent`, so it uses the site CSS.
    nonisolated private func htmlFragmentResponse(_ html: String) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK",
                     headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: Data(html.utf8))
    }

    /// `customtasks.html` — list of custom tasks (each → editor) + Add button.
    @MainActor private func customTasksManagerHTML() -> String {
        let tasks = (try? sqlite?.allCustomTaskRecords()) ?? []
        var s = "<div class='container'><section class='header'>"
        s += "<h2 class='title'>LocalRadio</h2><h3 class='title'>Custom Tasks</h3>"
        s += "<table class='u-full-width'><thead><tr><th>ID</th><th>Task</th></tr></thead><tbody>"
        for t in tasks {
            guard let id = t.id else { continue }
            s += "<tr><td>"
            s += "<a class='button button-primary' type='submit' onclick=\"loadContent('editcustomtask.html?id=\(id)');\">\(id)</a>"
            s += "</td><td>\(htmlText(t.taskName))</td></tr>"
        }
        s += "</tbody></table>"
        s += "<form action='javascript:loadContent(&quot;editcustomtask.html&quot;)'>"
        s += "<br>&nbsp;<br>\n<input class='twelve columns button button-primary' type='submit' value='Add New Custom Task'></form>"
        s += "<br><a href='pipelinetools.html' target='_blank'>Pipeline Tools documentation</a><br>&nbsp;<br>"
        s += "<br>&nbsp;<br></section></div>"
        return s
    }

    /// `editcustomtask.html` — edit an existing task (id) or create a new one.
    /// Field names match the `custom_task` columns; `task_json` is edited as raw
    /// JSON (`{"tasks":[{"path":..,"arguments":[..]}]}`). Save → storecustomtask.html.
    @MainActor private func editCustomTaskHTML(id: Int64?) -> String {
        let task: CustomTask = id.flatMap { try? sqlite?.customTask(forID: $0) ?? nil } ?? CustomTask.prototype()
        let isEditing = task.id != nil

        func text(_ label: String, _ name: String, _ value: String, type: String = "text") -> String {
            "<label for='\(name)'>\(label)</label><input class='twelve columns value-prop' type='\(type)' \(Self.verbatimInputAttributes) "
                + "id='\(name)' name='\(name)' value='\(htmlAttribute(value))'>"
        }

        var s = "<div class='container'><section class='header'>"
        s += "<h2 class='title'>LocalRadio</h2><h3 class='title'>\(isEditing ? "Edit Custom Task" : "Add New Custom Task")</h3>"
        s += "<form id='customTaskEditForm' onsubmit='event.preventDefault(); return storeCustomTaskRecord(this);' method='POST'>"
        if let taskID = task.id { s += "<input type='hidden' name='id' value='\(taskID)'>" }
        s += text("Task Name:", "task_name", task.taskName)
        s += text("Sample Rate:", "sample_rate", "\(task.sampleRate)", type: "number")
        s += text("Channels:", "channels", "\(task.channels)", type: "number")
        s += text("Input Buffer Size:", "input_buffer_size", "\(task.inputBufferSize)", type: "number")
        s += text("AudioConverter Buffer Size:", "audioconverter_buffer_size", "\(task.audioconverterBufferSize)", type: "number")
        s += text("AudioQueue Buffer Size:", "audioqueue_buffer_size", "\(task.audioqueueBufferSize)", type: "number")
        s += "<label>Task Pipeline — executables piped left → right (each stage's stdout feeds the next) "
        s += "(<a href='pipelinetools.html' target='_blank'>tool documentation</a>):</label>"
        // Graphical index of the pipeline. Built/refreshed by JS (initCustomTaskEditor
        // in localradio.js); clicking a node scrolls to that stage's editor below.
        s += "<a id='pipeline-overview'></a><div id='pipeline-overview-graphic' class='ct-pipeline'></div>"
        // data-tools feeds the JS mirror of customTaskStageHTML (new stages
        // added client-side need the same Tool pop-up options).
        let toolsAttribute = htmlAttribute(customTaskToolNames().joined(separator: ","))
        s += "<div id='task-stages' data-tools='\(toolsAttribute)'>\(customTaskStagesHTML(task.taskJson))</div>"
        s += "<input class='button' type='button' value='+ Add Stage' onclick='addCustomTaskStage();'>"
        // JS gathers the stage/argument fields into this hidden field on submit.
        s += "<input type='hidden' name='task_json' id='task_json_hidden' value=''>"
        s += "<br>&nbsp;<br><input class='twelve columns button button-primary' type='submit' value='Save Changes'>"
        if isEditing {
            // Like the Tuner pages' Listen button: plays what's on the form.
            // Saves the edits first, since the pipeline is built from the DB.
            s += "<br>&nbsp;<br><input class='twelve columns button button-primary' type='button' value='Listen' "
            s += "onclick='editCustomTaskListenButtonClicked(this.form, \(task.id!));' "
            s += "title='Save changes and listen to this custom task.'>"
        }
        s += "</form>"
        if isEditing {
            s += "<form id='deleteCustomTaskForm' onsubmit='event.preventDefault(); return deleteCustomTaskRecord(this);' method='POST'>"
            s += "<input type='hidden' name='id' value='\(task.id!)'>"
            s += "<input type='hidden' id='task_name' name='task_name' value='\(htmlAttribute(task.taskName))'>"
            s += "<br>&nbsp;<br><input class='twelve columns button' type='submit' value='Delete This Custom Task'></form>"
        }
        s += "<br>&nbsp;<br></section></div>"
        return s
    }

    /// Tool names offered by the stage editor's Tool pop-up: the bundled
    /// Contents/Helpers executables plus whitelisted system tools. Stored as
    /// bare names in `task_json`; `SDRController.resolveToolPath` maps them
    /// back to real paths when the pipeline starts.
    nonisolated static let systemToolPaths = ["nc": "/usr/bin/nc"]

    nonisolated private func customTaskToolNames() -> [String] {
        var names: Set<String> = []
        let helpersURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        if let entries = try? FileManager.default.contentsOfDirectory(at: helpersURL, includingPropertiesForKeys: nil) {
            for url in entries
            where FileManager.default.isExecutableFile(atPath: url.path) && !url.lastPathComponent.hasSuffix(".dylib") {
                names.insert(url.lastPathComponent)
            }
        }
        // The streaming sink is managed by the app itself; pipelines reach it
        // over UDP (PCMUDPSender), so it makes no sense as a stage.
        names.remove("LiveAudioServer")
        names.formUnion(Self.systemToolPaths.keys)
        return names.sorted()
    }

    /// Renders the structured task-pipeline editor from `task_json`. One block
    /// per pipe stage (tool pop-up / custom path + argument list). The matching
    /// JS in localradio.js adds/removes stages/arguments and serializes them
    /// back to `task_json` on save, so the markup here and there must stay in sync.
    @MainActor private func customTaskStagesHTML(_ json: String) -> String {
        var stages: [(path: String, args: [String])] = []
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tasks = obj["tasks"] as? [[String: Any]] {
            for t in tasks {
                let path = (t["path"] as? String) ?? ""
                let args = (t["arguments"] as? [Any])?.compactMap { $0 as? String } ?? []
                stages.append((path, args))
            }
        }
        if stages.isEmpty { stages = [("", [])] }
        let tools = customTaskToolNames()
        return stages.map { customTaskStageHTML(path: $0.path, args: $0.args, tools: tools) }.joined()
    }

    /// Attributes that stop WebKit's smart quotes/dashes and autocorrect from
    /// mangling command-line text ("--text" would otherwise become an em dash).
    nonisolated static let verbatimInputAttributes =
        "autocomplete='off' autocorrect='off' autocapitalize='none' spellcheck='false'"

    nonisolated private func customTaskStageHTML(path: String, args: [String], tools: [String]) -> String {
        var argRows = ""
        for arg in (args.isEmpty ? [""] : args) {
            argRows += "<div class='task-arg-row'><input class='task-arg' type='text' \(Self.verbatimInputAttributes) value='\(htmlAttribute(arg))' style='width:80%;'> "
            argRows += "<input class='button' type='button' value='-' onclick='removeCustomTaskArgument(this);'></div>"
        }
        // A bare name in `path` selects that tool; anything with a "/" (or an
        // unknown name) falls back to the Custom path text field.
        let isKnownTool = !path.isEmpty && !path.contains("/") && tools.contains(path)
        let selected = path.isEmpty ? (tools.first ?? "__custom__") : (isKnownTool ? path : "__custom__")

        var s = "<div class='task-stage' style='border:1px solid #bbb; border-radius:4px; padding:10px; margin-bottom:10px;'>"
        s += "<a href='#pipeline-overview' class='ct-back-link' onclick='return scrollToPipelineOverview();'>↑ Pipeline overview</a>"
        s += "<label>Tool</label>"
        s += "<select class='task-tool u-full-width' onchange='customTaskToolChanged(this);'>"
        for tool in tools {
            s += "<option value='\(htmlAttribute(tool))'\(tool == selected ? " selected" : "")>\(htmlText(tool))</option>"
        }
        s += "<option value='__custom__'\(selected == "__custom__" ? " selected" : "")>Custom path…</option>"
        s += "</select>"
        let pathStyle = selected == "__custom__" ? "" : " style='display:none;'"
        s += "<input class='task-path u-full-width' type='text' \(Self.verbatimInputAttributes) value='\(htmlAttribute(path))' placeholder='/path/to/tool'\(pathStyle)>"
        s += "<label>Arguments</label><div class='task-args'>\(argRows)</div>"
        s += "<input class='button' type='button' value='+ Argument' onclick='addCustomTaskArgument(this);'> "
        s += "<input class='button' type='button' value='+ Insert Stage Above' onclick='insertCustomTaskStageAbove(this);'> "
        s += "<input class='button' type='button' value='Remove Stage' onclick='removeCustomTaskStage(this);'>"
        s += "</div>"
        return s
    }

    /// Inserts (no id) or updates (id present) a `custom_task` from the editor form.
    @MainActor private func upsertCustomTask(fromBody body: Data) {
        let fields = formFields(fromBody: body)
        var task: CustomTask
        if let idString = fields["id"], let id = Int64(idString),
           let existing = (try? sqlite?.customTask(forID: id)) ?? nil {
            task = existing
        } else {
            task = CustomTask.prototype()
        }

        if let v = fields["task_name"] { task.taskName = v }
        if let v = fields["task_json"] { task.taskJson = v }
        if let v = fields["sample_rate"], let n = Int(v) { task.sampleRate = n }
        if let v = fields["channels"], let n = Int(v) { task.channels = n }
        if let v = fields["input_buffer_size"], let n = Int(v) { task.inputBufferSize = n }
        if let v = fields["audioconverter_buffer_size"], let n = Int(v) { task.audioconverterBufferSize = n }
        if let v = fields["audioqueue_buffer_size"], let n = Int(v) { task.audioqueueBufferSize = n }

        if task.id != nil {
            try? sqlite?.updateCustomTaskRecord(task)
        } else {
            try? sqlite?.insertCustomTaskRecord(&task)
        }
    }

    // MARK: Tuner (advanced form + insert-new-frequency)

    /// `%%TUNER_FORM%%` for tuner_advanced.html — a full new-frequency form whose
    /// field names match the `frequency` table columns. Submits (via
    /// `insertNewFrequencyRecord`) to insertnewfrequency.html.
    @MainActor private func newFrequencyFormHTML() -> String {
        let p = Frequency.prototype()

        func text(_ label: String, _ name: String, _ value: String, type: String = "text", step: String? = nil) -> String {
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            return "<label for='\(name)'>\(label)</label><input class='twelve columns value-prop' type='\(type)' \(Self.verbatimInputAttributes) "
                + "id='\(name)' name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)>"
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
        s += text("USB Device:", "usb_device_string", p.usbDeviceString)
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

        func text(_ label: String, _ name: String, _ value: String, type: String = "text", step: String? = nil) -> String {
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            return "<label for='\(name)'>\(label)</label><input class='twelve columns value-prop' type='\(type)' \(Self.verbatimInputAttributes) "
                + "id='\(name)' name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)>"
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
        s += text("USB Device:", "scan_usb_device_string", c.scanUsbDeviceString)
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
        if let existing = try? sqlite?.categoryRecord(forName: name), existing != nil { return }
        var record = Category.prototype(name: name)
        try? sqlite?.insertCategoryRecord(&record)
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
        s += "<br><br>frequency: \(htmlText(f.formattedFrequency))<br>modulation: \(htmlText(modulation))<br>sample rate: \(f.sampleRate)<br><br>"
        return (f.stationName, s)
    }

    /// `%%EDIT_FAVORITE_NAME%%` + `%%EDIT_FAVORITE%%` — the favorite edit form.
    /// Field `name`s match the `frequency` table columns and the client-side
    /// validator in `localradio.js`; Save posts to `storefrequency.html` and
    /// Delete to `deletefrequency.html` (both handled by `appStateResponse`).
    @MainActor private func editFavorite(id: Int64) -> (name: String, item: String) {
        guard let f = (try? sqlite?.frequencyRecord(forID: id)) ?? nil else {
            return ("", "Error getting favorite id = \(id)")
        }

        func text(_ label: String, _ name: String, _ value: String, id elementID: String? = nil,
                  type: String = "text", step: String? = nil) -> String {
            let idAttr = elementID.map { " id='\($0)'" } ?? ""
            let stepAttr = step.map { " step='\($0)'" } ?? ""
            return "<label>\(label)<input class='u-full-width' type='\(type)'\(idAttr) \(Self.verbatimInputAttributes) "
                + "name='\(name)' value='\(htmlAttribute(value))'\(stepAttr)></label>"
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
        s += text("USB Device", "usb_device_string", f.usbDeviceString)
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
        d += row("sampling mode", "\(f.samplingMode)")
        d += row("oversampling", "\(f.oversampling)")
        d += row("tuner gain", "\(f.tunerGain)")
        d += row("tuner agc", "\(f.tunerAgc)")
        d += row("rtl-sdr options", "pad \(f.options)")
        d += row("fir size", "\(f.firSize)")
        d += row("atan math", f.atanMath)
        d += row("audio output filter", "rate 48000 \(f.audioOutputFilter)")
        d += row("bias-t", "\(f.biasTFlag)")
        d += row("usb device", f.usbDeviceString)
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
            dict["stereo_flag"] = f.stereoFlag ? 1 : 0
        } else {
            dict["station_name"] = sdrController?.statusFunction ?? "Not Playing"
            dict["short_frequency"] = ""
        }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
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
        case "info.html":
            dict["LOCALRADIO_ANIMATION"] = loadSVG(named: "LocalRadio-animation")
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
