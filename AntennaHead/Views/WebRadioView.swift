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
        webView.customUserAgent = "AntennaHead/1.0"
        webView.navigationDelegate = context.coordinator
        context.coordinator.startObservingReload(of: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.credentials = credentials
        if webView.url?.host == nil {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var credentials: HTTPAuthCredentials.Credentials?
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
            webView?.reload()
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
