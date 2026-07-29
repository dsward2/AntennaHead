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
        context.coordinator.startObservingReload(of: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.credentials = credentials
        context.coordinator.targetURL = url
        if webView.url?.host == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var credentials: HTTPAuthCredentials.Credentials?
        var targetURL: URL?
        private weak var webView: WKWebView?

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
