import Foundation
import GRDB

struct FreqCat: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var freqId: Int64
    var catId: Int64

    static let databaseTableName = "freq_cat"

    enum CodingKeys: String, CodingKey {
        case id
        case freqId = "freq_id"
        case catId = "cat_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static let frequency = belongsTo(Frequency.self, using: ForeignKey(["freq_id"]))
    static let category = belongsTo(Category.self, using: ForeignKey(["cat_id"]))
}
