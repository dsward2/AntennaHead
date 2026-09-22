import Foundation
import GRDB

/// One RSS/Atom subscription for the "Speak RSS Headlines" page — added,
/// edited, and deleted from that page itself (see `AntennaHeadHTTPServer`'s
/// `editRSSFeed`/`insertNewRSSFeed`/`saveRSSFeed`/`deleteRSSFeed`), the same
/// way Favorites/Categories manage `Frequency`/`Category` records. No
/// `enabled` column: every feed is listed with a checkbox, checked by
/// default, each time the Speak RSS Headlines page loads — same as Play
/// Audio Files' file list — so there's no separate on/off state to track.
struct RSSFeed: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var feedURL: String
    /// `PCMSpeechSynth --voice` identifier, or empty for "use the default
    /// voice" (resolved via `SpeechVoicePreference`).
    var voiceIdentifier: String
    /// `"title"` (just the headline) or `"title_and_summary"` (headline plus
    /// the feed's short description/summary).
    var readMode: String

    static let databaseTableName = "rss_feed"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case feedURL = "feed_url"
        case voiceIdentifier = "voice_identifier"
        case readMode = "read_mode"
    }

    /// Values `readMode` may hold — mirrors the "Read Mode" `<select>` on the
    /// feed edit page.
    enum ReadMode {
        static let titleOnly = "title"
        static let titleAndSummary = "title_and_summary"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func prototype(name: String = "New Feed") -> RSSFeed {
        RSSFeed(id: nil, name: name, feedURL: "", voiceIdentifier: "", readMode: ReadMode.titleOnly)
    }
}
