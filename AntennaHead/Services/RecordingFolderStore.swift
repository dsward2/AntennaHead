import Foundation

/// Holds the sandbox security-scoped folder AntennaHead writes
/// ControlBooth-triggered ('RecS') recordings into.
///
/// This folder is picked from AntennaHead's own Settings (see
/// `ConfigurationView.chooseRecordingFolder`), not from ControlBooth — a
/// security-scoped bookmark minted by ControlBooth (unsandboxed) carries no
/// real sandbox grant for a different, unrelated sandboxed app to redeem;
/// only a bookmark AntennaHead itself mints from its own NSOpenPanel
/// interaction does. (Confirmed the hard way: an unsandboxed-minted bookmark
/// resolved fine within ControlBooth's own process but always failed with
/// NSCocoaErrorDomain 259 when AntennaHead tried to resolve it.)
///
/// Access is acquired once, at construction, and held for the app's
/// lifetime — recordings can be triggered by an AppleEvent at any time, so
/// there's no natural "about to record" moment to bracket access around.
@MainActor
final class RecordingFolderStore {
    static let shared = RecordingFolderStore()

    static let bookmarkKey = "AntennaHeadRecordingFolderBookmark"

    private(set) var folderURL: URL?
    private var isAccessing = false

    private init() {
        reload()
    }

    /// Re-resolves the stored bookmark and (re)acquires security-scoped
    /// access, releasing any previously-held access first. Call once at
    /// launch (done automatically) and again right after a new bookmark is
    /// saved (see `ConfigurationView.chooseRecordingFolder`).
    func reload() {
        release()
        guard let base64 = (try? SQLiteController.shared.appSettingsValue(forKey: Self.bookmarkKey)) ?? nil,
              let data = Data(base64Encoded: base64) else {
            return
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return
        }
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? SQLiteController.shared.storeAppSettingsValue(fresh.base64EncodedString(), forKey: Self.bookmarkKey)
        }
        isAccessing = url.startAccessingSecurityScopedResource()
        folderURL = url
    }

    private func release() {
        if isAccessing, let folderURL {
            folderURL.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
        folderURL = nil
    }
}
