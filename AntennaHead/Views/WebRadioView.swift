import SwiftUI
import WebKit

struct WebRadioView: NSViewRepresentable {
    let url: URL
    /// Credentials used to silently answer HTTP Basic-auth challenges, or
    /// `nil` when the target server is not protected.
    var credentials: HTTPAuthCredentials.Credentials?

    func makeCoordinator() -> Coordinator {
        Coordinator(credentials: credentials)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.customUserAgent = "AntennaHead/1.0"
        webView.navigationDelegate = context.coordinator
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

        init(credentials: HTTPAuthCredentials.Credentials?) {
            self.credentials = credentials
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
