import Foundation

/// System-wide port configuration, stored in `local_radio_config` and editable
/// from the Configuration tab's "Change Configuration…" sheet (like LocalRadio).
/// Saved values take effect when services restart (`settingsDidChangeNotification`).
///
/// Keys are AntennaHead-prefixed on purpose: the skeleton database still seeds
/// LocalRadio's original port rows (`LocalRadioServerHTTPPort` = 17002, …),
/// which must not silently override AntennaHead's defaults.
struct PortSettings: Equatable {
    /// AntennaHead web UI HTTP port.
    var webHTTP: UInt16 = 8090
    /// AntennaHead web UI HTTPS port (used when TLS is enabled).
    var webHTTPS: UInt16 = 8094
    /// LiveAudioServer HTTP port (audio stream + LAS web UI).
    var streamingHTTP: UInt16 = 8080
    /// LiveAudioServer HTTPS port (used when TLS is enabled).
    var streamingHTTPS: UInt16 = 8443
    /// UDP port receiving rtl_fm's `-c` status feed.
    var statusUDP: UInt16 = 6021
    /// UDP port LiveAudioServer receives pipeline PCM on.
    var audioUDP: UInt16 = 6020

    static let `default` = PortSettings()

    private static let storageKeys: [(WritableKeyPath<PortSettings, UInt16>, String)] = [
        (\.webHTTP, "AntennaHeadServerHTTPPort"),
        (\.webHTTPS, "AntennaHeadServerHTTPSPort"),
        (\.streamingHTTP, "AntennaHeadStreamingServerHTTPPort"),
        (\.streamingHTTPS, "AntennaHeadStreamingServerHTTPSPort"),
        (\.statusUDP, "AntennaHeadStatusPort"),
        (\.audioUDP, "AntennaHeadAudioPort")
    ]

    /// Stored ports, falling back to the defaults for missing/invalid values.
    @MainActor static func load(sqlite: SQLiteController? = .shared) -> PortSettings {
        var settings = PortSettings()
        for (keyPath, key) in storageKeys {
            if let stored = ((try? sqlite?.localRadioAppSettingsValue(forKey: key)) ?? nil),
               let port = UInt16(stored), port > 0 {
                settings[keyPath: keyPath] = port
            }
        }
        return settings
    }

    @MainActor func store(sqlite: SQLiteController? = .shared) {
        for (keyPath, key) in Self.storageKeys {
            try? sqlite?.storeLocalRadioAppSettingsValue("\(self[keyPath: keyPath])", forKey: key)
        }
    }
}
