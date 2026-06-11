import Foundation
import GRDB

final class AppDatabase {
    static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("AppDatabase initialization failed: \(error)")
        }
    }()

    let dbQueue: DatabaseQueue

    convenience init() throws {
        let url = try AppDatabase.databaseURL()
        try AppDatabase.bootstrapFromSkeletonIfNeeded(at: url)
        try self.init(path: url.path)
    }

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(self.dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_skeleton") { _ in
            // Skeleton already ships the v1 schema and seed rows; nothing to do.
        }
        return m
    }

    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AntennaHead", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("AntennaHead.sqlite3")
    }

    private static func bootstrapFromSkeletonIfNeeded(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard let seed = Bundle.main.url(forResource: "data_skeleton", withExtension: "sqlite3") else {
            throw AppDatabaseError.skeletonMissing
        }
        try FileManager.default.copyItem(at: seed, to: url)
    }
}

enum AppDatabaseError: Error {
    case skeletonMissing
}
