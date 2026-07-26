import Foundation
import GRDB

struct AppConfig: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var configKey: String
    var configValue: String

    static let databaseTableName = "app_config"

    enum CodingKeys: String, CodingKey {
        case id
        case configKey = "config_key"
        case configValue = "config_value"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    static func value(forKey key: String, in db: Database) throws -> String? {
        try AppConfig
            .filter(Column("config_key") == key)
            .fetchOne(db)?
            .configValue
    }

    static func set(_ value: String, forKey key: String, in db: Database) throws {
        if var existing = try AppConfig.filter(Column("config_key") == key).fetchOne(db) {
            existing.configValue = value
            try existing.update(db)
        } else {
            var row = AppConfig(id: nil, configKey: key, configValue: value)
            try row.insert(db)
        }
    }
}
