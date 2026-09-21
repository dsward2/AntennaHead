import Foundation
import GRDB

/// Builds a ShareFile from the local database.
struct ShareExporter {
    let db: DatabaseQueue

    init(db: DatabaseQueue = AppDatabase.shared.dbQueue) { self.db = db }

    /// What to export. Favorites in a selected category are always included
    /// with it; extra favorites can be picked on their own.
    struct Selection: Equatable {
        var categoryIDs: Set<Int64> = []
        var favoriteIDs: Set<Int64> = []
    }

    struct Metadata {
        var title: String = ""
        var region: String = ""
        var notes: String = ""
    }

    /// Every category and favorite.
    func everything() throws -> Selection {
        try db.read { db in
            Selection(categoryIDs: Set(try Category.fetchAll(db).compactMap(\.id)),
                      favoriteIDs: Set(try Frequency.fetchAll(db).compactMap(\.id)))
        }
    }

    func makeFile(_ selection: Selection, metadata: Metadata = Metadata(), now: Date = Date()) throws -> ShareFile {
        try db.read { db in
            let categories = try Category.order(Column("category_name")).fetchAll(db)
                .filter { selection.categoryIDs.contains($0.id ?? -1) }
            let links = try FreqCat.fetchAll(db)
            let namesByID = Dictionary(uniqueKeysWithValues: categories.compactMap { c in c.id.map { ($0, c.categoryName) } })

            var favoriteIDs = selection.favoriteIDs
            for link in links where namesByID[link.catId] != nil { favoriteIDs.insert(link.freqId) }

            let favorites = try Frequency.order(Column("frequency"), Column("station_name")).fetchAll(db)
                .filter { favoriteIDs.contains($0.id ?? -1) }
                .map { f -> SharedFavorite in
                    let names = links.filter { $0.freqId == f.id }.compactMap { namesByID[$0.catId] }.sorted()
                    return SharedFavorite(f, categoryNames: names)
                }

            func trimmed(_ s: String) -> String? {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return ShareFile(format: ShareFile.formatID, version: ShareFile.currentVersion,
                             exportedAt: ISO8601DateFormatter().string(from: now),
                             appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                             title: trimmed(metadata.title), region: trimmed(metadata.region),
                             notes: trimmed(metadata.notes),
                             categories: categories.map(SharedCategory.init), favorites: favorites)
        }
    }

    static func encode(_ file: ShareFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    static func suggestedFileName(for file: ShareFile, now: Date = Date()) -> String {
        let base = (file.title ?? "AntennaHead tuning data")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)).joined(separator: "-")
        return "\(base.prefix(60)).antennahead.json"
    }
}
