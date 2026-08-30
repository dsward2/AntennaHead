import SwiftUI

/// Shared background treatment for the native SwiftUI tabs (Configuration,
/// Security, About, FCC Search) so they match the near-black `#1C1C1E` that
/// the web-backed tabs render, instead of macOS's lighter grouped-`Form`
/// window chrome.
///
/// Pairs with the `AppBackground` asset-catalog colour, the `--ah-bg` /
/// `--bg` CSS tokens in `Web/css/custom.css` and `StatusWebView`'s shell,
/// and `WKWebView.underPageBackgroundColor` (set in `WebRadioView` and
/// `StatusWebView`).
extension View {
    /// Hides the default grouped-`Form` / scroll-view background and paints
    /// the shared `AppBackground` colour behind the content. Apply to the
    /// `Form` (or its enclosing container) in each native tab.
    func harmonizedFormBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
    }
}
