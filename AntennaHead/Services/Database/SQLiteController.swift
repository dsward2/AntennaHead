import Foundation
import GRDB

final class SQLiteController {
    static let shared = SQLiteController(database: .shared)

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    private var dbQueue: DatabaseQueue { database.dbQueue }

    // MARK: Frequency

    func allFrequencyRecords() throws -> [Frequency] {
        try dbQueue.read { db in
            try Frequency.order(Column("frequency")).fetchAll(db)
        }
    }

    func frequencyRecord(forID id: Int64) throws -> Frequency? {
        try dbQueue.read { db in try Frequency.fetchOne(db, key: id) }
    }

    func frequencyRecord(forFrequency frequency: Int) throws -> Frequency? {
        try dbQueue.read { db in
            try Frequency.filter(Column("frequency") == frequency).fetchOne(db)
        }
    }

    func allFrequencyRecords(forCategoryID categoryID: Int64) throws -> [Frequency] {
        try dbQueue.read { db in
            try Frequency
                .joining(required: Frequency.hasMany(FreqCat.self).filter(Column("cat_id") == categoryID))
                .order(Column("frequency"))
                .fetchAll(db)
        }
    }

    func deleteFrequencyRecord(forID id: Int64) throws {
        try dbQueue.write { db in
            _ = try Frequency.deleteOne(db, key: id)
            _ = try FreqCat.filter(Column("freq_id") == id).deleteAll(db)
        }
    }

    @discardableResult
    func insertFrequencyRecord(_ record: inout Frequency) throws -> Int64 {
        try dbQueue.write { db in
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    func updateFrequencyRecord(_ record: Frequency) throws {
        try dbQueue.write { db in try record.update(db) }
    }

    // MARK: Category

    func allCategoryRecords() throws -> [Category] {
        try dbQueue.read { db in
            try Category.order(Column("category_name")).fetchAll(db)
        }
    }

    func categoryRecord(forID id: Int64) throws -> Category? {
        try dbQueue.read { db in try Category.fetchOne(db, key: id) }
    }

    func categoryRecord(forName name: String) throws -> Category? {
        try dbQueue.read { db in
            try Category.filter(Column("category_name") == name).fetchOne(db)
        }
    }

    func deleteCategoryRecord(forID id: Int64) throws {
        try dbQueue.write { db in
            _ = try Category.deleteOne(db, key: id)
            _ = try FreqCat.filter(Column("cat_id") == id).deleteAll(db)
        }
    }

    @discardableResult
    func insertCategoryRecord(_ record: inout Category) throws -> Int64 {
        try dbQueue.write { db in
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    func updateCategoryRecord(_ record: Category) throws {
        try dbQueue.write { db in try record.update(db) }
    }

    // MARK: FreqCat (junction)

    func allFreqCatRecords() throws -> [FreqCat] {
        try dbQueue.read { db in try FreqCat.fetchAll(db) }
    }

    func freqCatRecords(forCategoryID categoryID: Int64) throws -> [FreqCat] {
        try dbQueue.read { db in
            try FreqCat.filter(Column("cat_id") == categoryID).fetchAll(db)
        }
    }

    func freqCatRecordExists(forFrequencyID freqID: Int64, categoryID: Int64) throws -> Bool {
        try dbQueue.read { db in
            try FreqCat
                .filter(Column("freq_id") == freqID && Column("cat_id") == categoryID)
                .fetchCount(db) > 0
        }
    }

    func freqCatRecord(forFrequencyID freqID: Int64, categoryID: Int64) throws -> FreqCat? {
        try dbQueue.read { db in
            try FreqCat
                .filter(Column("freq_id") == freqID && Column("cat_id") == categoryID)
                .fetchOne(db)
        }
    }

    func insertFreqCatRecord(forFrequencyID freqID: Int64, categoryID: Int64) throws {
        try dbQueue.write { db in
            var row = FreqCat(id: nil, freqId: freqID, catId: categoryID)
            try row.insert(db)
        }
    }

    func deleteFreqCatRecord(forFrequencyID freqID: Int64, categoryID: Int64) throws {
        try dbQueue.write { db in
            _ = try FreqCat
                .filter(Column("freq_id") == freqID && Column("cat_id") == categoryID)
                .deleteAll(db)
        }
    }

    // MARK: Custom Tasks

    func allCustomTaskRecords() throws -> [CustomTask] {
        try dbQueue.read { db in
            try CustomTask.order(Column("task_name")).fetchAll(db)
        }
    }

    func customTask(forID id: Int64) throws -> CustomTask? {
        try dbQueue.read { db in try CustomTask.fetchOne(db, key: id) }
    }

    @discardableResult
    func insertCustomTaskRecord(_ record: inout CustomTask) throws -> Int64 {
        try dbQueue.write { db in
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    func updateCustomTaskRecord(_ record: CustomTask) throws {
        try dbQueue.write { db in try record.update(db) }
    }

    func deleteCustomTaskRecord(forID id: Int64) throws {
        try dbQueue.write { db in _ = try CustomTask.deleteOne(db, key: id) }
    }

    // MARK: App config (local_radio_config)

    func localRadioAppSettingsValue(forKey key: String) throws -> String? {
        try dbQueue.read { db in try AppConfig.value(forKey: key, in: db) }
    }

    func storeLocalRadioAppSettingsValue(_ value: String, forKey key: String) throws {
        try dbQueue.write { db in try AppConfig.set(value, forKey: key, in: db) }
    }
}
