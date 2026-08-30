import Foundation

/// The App Group container AntennaHead and ControlBooth share for
/// ControlBooth-triggered ('RecS'/'RecP' AppleEvent) and LiveAudioServer
/// tab recordings. Replaces the old NSOpenPanel + security-scoped bookmark
/// (formerly `RecordingFolderStore`): the destination is a fixed folder
/// inside the App Group container, always resolvable from AntennaHead's own
/// entitlements — no picker, no bookmark, and ControlBooth (unsandboxed) can
/// read/write the same path with no extra grant of its own.
enum SharedRecordingFolder {
    nonisolated static let appGroupIdentifier = "group.com.dsward.antennahead"

    /// Creates the folder on first access if it doesn't exist yet. `nil`
    /// only if the App Group entitlement itself is missing or misconfigured.
    nonisolated static var url: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let folder = container.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
