import SwiftUI
import WebKit

struct WebRadioView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.customUserAgent = "AntennaHead/1.0"
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url?.host == nil {
            webView.load(URLRequest(url: url))
        }
    }
}
