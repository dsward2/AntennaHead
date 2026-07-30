import SwiftUI
import WebKit

struct WebRadioView: NSViewRepresentable {
    let url: URL
    /// Credentials used to silently answer HTTP Basic-auth challenges, or
    /// `nil` when the target server is not protected.
    var credentials: HTTPAuthCredentials.Credentials?

    /// Posted by the Commands ▸ Reload Web View menu item; every live
    /// `WebRadioView` reloads its page (port of LocalRadio's `reloadWebView:`).
    static let reloadNotification = Notification.Name("WebRadioView.reload")

    func makeCoordinator() -> Coordinator {
        Coordinator(credentials: credentials)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isInspectable = true
        webView.customUserAgent = "AntennaHead/1.0"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.configuration.userContentController.add(context.coordinator, name: "recorderBridge")
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: Self.recorderBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        context.coordinator.startObservingReload(of: webView)
        return webView
    }

    // Reroutes the LiveAudioServer status page's recorder Start/Stop calls
    // through `recorderBridge` (see `Coordinator.userContentController`) so
    // AntennaHead can substitute a container-writable temp path for whatever
    // the user typed, then move the finished file into AntennaHead's own
    // sandboxed Recording folder once LiveAudioServer confirms the file is
    // closed. Also patches the displayed `path` in status responses back to
    // what the user typed, so the temp path never leaks into the UI. A no-op
    // on any other page, since only LiveAudioServer's page calls these routes.
    private static let recorderBridgeScript = """
    (function() {
      if (window.__antennaHeadRecorderBridge) return;
      window.__antennaHeadRecorderBridge = true;

      const displayPaths = {};
      const tempPaths = {};
      const resolvers = {};
      let seq = 0;

      window.__recorderBridgeResolve = function(id, result) {
        const r = resolvers[id];
        if (r) { delete resolvers[id]; r(result); }
      };

      function patchEnvelope(env) {
        if (!env) return;
        ['mp3', 'aac'].forEach(fmt => {
          const status = env[fmt];
          if (status && tempPaths[fmt] && status.path === tempPaths[fmt]) {
            status.path = displayPaths[fmt];
          }
        });
      }

      const nativeFetch = window.fetch.bind(window);
      window.fetch = async function(input, init) {
        const url = (typeof input === 'string') ? input : input.url;
        const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.recorderBridge;

        const startM = /^\\/api\\/recorder\\/(mp3|aac)\\/start$/.exec(url);
        if (startM && bridge) {
          const fmt = startM[1];
          let bodyObj = {};
          try { bodyObj = JSON.parse((init && init.body) || '{}'); } catch (e) {}
          const id = 'r' + (seq++);
          const bridged = await new Promise(resolve => {
            resolvers[id] = resolve;
            bridge.postMessage({ id: id, action: 'start', format: fmt, path: bodyObj.path || '' });
          });
          if (bridged && bridged.error) {
            return new Response(JSON.stringify({ error: bridged.error }), { status: 500 });
          }
          if (bridged && bridged.tempPath) {
            displayPaths[fmt] = bodyObj.path;
            tempPaths[fmt] = bridged.tempPath;
            init = Object.assign({}, init, { body: JSON.stringify({ path: bridged.tempPath }) });
          }
        }

        const resp = await nativeFetch(url, init);

        const stopM = /^\\/api\\/recorder\\/(mp3|aac)\\/stop$/.exec(url);
        if (stopM && resp.ok && bridge) {
          bridge.postMessage({ action: 'stop', format: stopM[1] });
        }

        const looksLikeRecorderJSON = /^\\/api\\/recorder(\\/(mp3|aac)\\/(start|pause|resume|stop))?$/.test(url)
                                    || /^\\/status\\.json$/.test(url);
        if (looksLikeRecorderJSON && resp.ok) {
          try {
            const data = await resp.clone().json();
            if (data.mp3 || data.aac) {
              patchEnvelope(data);
              return new Response(JSON.stringify(data), { status: resp.status, headers: resp.headers });
            }
            if (data.recorder) {
              patchEnvelope(data.recorder);
              return new Response(JSON.stringify(data), { status: resp.status, headers: resp.headers });
            }
          } catch (e) {}
        }

        if (stopM && resp.ok) {
          delete displayPaths[stopM[1]];
          delete tempPaths[stopM[1]];
        }

        return resp;
      };
    })();
    """

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.credentials = credentials
        context.coordinator.targetURL = url
        if webView.url?.host == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var credentials: HTTPAuthCredentials.Credentials?
        var targetURL: URL?
        private weak var webView: WKWebView?

        /// format ("mp3"/"aac") → (container-local temp file LiveAudioServer is
        /// actually writing to, real destination to move it to on stop). See
        /// `recorderBridgeScript` above and `userContentController(_:didReceive:)`.
        private var pendingRecordings: [String: (temp: URL, final: URL)] = [:]

        init(credentials: HTTPAuthCredentials.Credentials?) {
            self.credentials = credentials
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func startObservingReload(of webView: WKWebView) {
            self.webView = webView
            NotificationCenter.default.addObserver(self, selector: #selector(reloadWebView),
                                                   name: WebRadioView.reloadNotification, object: nil)
        }

        @objc private func reloadWebView() {
            guard let webView else { return }
            if let url = targetURL {
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("WebRadioView navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("WebRadioView provisional navigation failed: \(error)")
        }

        /// `target="_blank"` links (Pipeline Tools docs, Credits): WKWebView
        /// can't open windows itself, so hand the URL to the default browser.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        /// Handles `window.alert()` calls — without this, WKWebView silently
        /// swallows the alert (no dialog, no error) instead of showing it, which
        /// is how the LiveAudioServer tab's recorder Start/Stop failures used to
        /// go completely unnoticed.
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            if let window = webView.window {
                alert.beginSheetModal(for: window) { _ in completionHandler() }
            } else {
                alert.runModal()
                completionHandler()
            }
        }

        /// Bridge for `recorderBridgeScript`: substitutes a container-writable
        /// temp path for the LiveAudioServer recorder to write to (a raw
        /// user-typed path like `~/Downloads/...` fails silently under the App
        /// Sandbox — child processes don't inherit AntennaHead's security-scoped
        /// file access, see `LiveAudioServerProcessManager.startRecording(at:)`),
        /// then moves the finished file into AntennaHead's configured Recording
        /// folder once LiveAudioServer confirms the file is closed.
        func userContentController(_ userContentController: WKUserContentController,
                                    didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let action = dict["action"] as? String,
                  let format = dict["format"] as? String else { return }
            MainActor.assumeIsolated {
                switch action {
                case "start":
                    guard let replyID = dict["id"] as? String else { return }
                    handleRecorderStart(format: format, typedPath: dict["path"] as? String ?? "", replyID: replyID)
                case "stop":
                    handleRecorderStop(format: format)
                default:
                    break
                }
            }
        }

        @MainActor
        private func handleRecorderStart(format: String, typedPath: String, replyID: String) {
            guard let folderURL = RecordingFolderStore.shared.folderURL else {
                resolveRecorderBridge(replyID: replyID, result: [
                    "error": "No recording folder is configured in AntennaHead's Settings — set one under Configuration → Recording."
                ])
                return
            }
            let typedName = (typedPath as NSString).lastPathComponent
            let filename = typedName.isEmpty ? "LiveAudioServer-\(format)" : typedName
            let finalURL = folderURL.appendingPathComponent(filename)
            let ext = (filename as NSString).pathExtension
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveAudioServer-\(format)-\(UUID().uuidString)")
                .appendingPathExtension(ext.isEmpty ? format : ext)
            pendingRecordings[format] = (temp: tempURL, final: finalURL)
            resolveRecorderBridge(replyID: replyID, result: ["tempPath": tempURL.path])
        }

        @MainActor
        private func handleRecorderStop(format: String) {
            guard let pair = pendingRecordings.removeValue(forKey: format) else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    if FileManager.default.fileExists(atPath: pair.final.path) {
                        try FileManager.default.removeItem(at: pair.final)
                    }
                    try FileManager.default.moveItem(at: pair.temp, to: pair.final)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Recording save failed"
                        alert.informativeText = "Could not save the \(format.uppercased()) recording to \(pair.final.path): \(error.localizedDescription)"
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }

        private func resolveRecorderBridge(replyID: String, result: [String: String]) {
            guard let webView,
                  let json = try? JSONSerialization.data(withJSONObject: result),
                  let jsonString = String(data: json, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__recorderBridgeResolve('\(replyID)', \(jsonString))")
        }

        /// Handles `window.prompt()` calls from the Custom Task copy/paste buttons.
        /// Copy: writes text directly to the clipboard and shows a read-only confirmation.
        /// Paste: shows an editable view pre-filled with clipboard contents.
        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let isCopy = prompt.hasPrefix("Copy")
            let text = defaultText ?? ""

            if isCopy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = isCopy ? "CLI Text Copied to Clipboard" : prompt
            alert.addButton(withTitle: "OK")
            if !isCopy { alert.addButton(withTitle: "Cancel") }

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 72))
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            let textView = NSTextView()
            textView.isEditable = !isCopy
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            textView.string = isCopy ? text : (NSPasteboard.general.string(forType: .string) ?? "")
            scrollView.documentView = textView
            alert.accessoryView = scrollView

            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    completionHandler(!isCopy && response == .alertFirstButtonReturn ? textView.string : nil)
                }
            } else {
                let response = alert.runModal()
                completionHandler(!isCopy && response == .alertFirstButtonReturn ? textView.string : nil)
            }
        }

        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Silently supply stored credentials for Basic-auth challenges;
            // fall back to default handling for anything else (e.g. TLS).
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  let creds = credentials,
                  challenge.previousFailureCount == 0 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let credential = URLCredential(user: creds.user,
                                           password: creds.password,
                                           persistence: .forSession)
            completionHandler(.useCredential, credential)
        }
    }
}
