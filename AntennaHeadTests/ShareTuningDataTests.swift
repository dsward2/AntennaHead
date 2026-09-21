import XCTest
import GRDB
@testable import AntennaHead

final class ShareTuningDataTests: XCTestCase {

    // MARK: Helpers

    /// A fresh database copied from the bundled skeleton (11 favorites, 4 categories).
    private func makeDB(emptied: Bool = false) throws -> DatabaseQueue {
        let seed = try XCTUnwrap(Bundle.main.url(forResource: "data_skeleton", withExtension: "sqlite3"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-test-\(UUID().uuidString).sqlite3")
        try FileManager.default.copyItem(at: seed, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let queue = try AppDatabase(path: url.path).dbQueue
        if emptied {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM freq_cat; DELETE FROM frequency; DELETE FROM category;")
            }
        }
        return queue
    }

    private func export(from db: DatabaseQueue, metadata: ShareExporter.Metadata = .init()) throws -> Data {
        let exporter = ShareExporter(db: db)
        let file = try exporter.makeFile(try exporter.everything(), metadata: metadata)
        return try ShareExporter.encode(file)
    }

    private func favorites(_ db: DatabaseQueue) throws -> [Frequency] { try db.read { try Frequency.fetchAll($0) } }
    private func categories(_ db: DatabaseQueue) throws -> [AntennaHead.Category] { try db.read { try AntennaHead.Category.fetchAll($0) } }
    private func linkCount(_ db: DatabaseQueue) throws -> Int { try db.read { try FreqCat.fetchCount($0) } }

    // MARK: Export

    func testExportEverythingRoundTripsAndOmitsMachineSpecificFields() throws {
        let db = try makeDB()
        try db.write { try $0.execute(sql: "UPDATE frequency SET usb_device_string = 'rtl=00000180'; UPDATE category SET scan_usb_device_string = 'rtl=00000180'") }
        let data = try export(from: db, metadata: .init(title: "Little Rock", region: "AR"))

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("usb_device_string"), "device serials must never be exported")
        XCTAssertFalse(json.contains("00000180"))

        let file = try ShareValidator.decode(data)
        XCTAssertEqual(file.title, "Little Rock")
        XCTAssertEqual(file.favorites.count, try favorites(db).count)
        XCTAssertEqual(file.categories.count, try categories(db).count)
        XCTAssertEqual(file.favorites.map(\.categories.count).reduce(0, +), try linkCount(db))
    }

    func testExportingACategoryBringsItsFavoritesButNotOthers() throws {
        let db = try makeDB()
        let cat = try XCTUnwrap(try categories(db).first { $0.categoryName == "NOAA Weather Radio" })
        let exporter = ShareExporter(db: db)
        let file = try exporter.makeFile(.init(categoryIDs: [try XCTUnwrap(cat.id)], favoriteIDs: []))
        XCTAssertEqual(file.categories.map(\.name), ["NOAA Weather Radio"])
        XCTAssertFalse(file.favorites.isEmpty)
        XCTAssertTrue(file.favorites.allSatisfy { $0.categories == ["NOAA Weather Radio"] })
        XCTAssertLessThan(file.favorites.count, try favorites(db).count)
    }

    // MARK: Import into an empty database

    func testImportIntoEmptyDatabaseAddsEverythingWithBiasTOffAndBlankDevice() throws {
        let source = try makeDB()
        try source.write { try $0.execute(sql: "UPDATE frequency SET bias_t_flag = 1; UPDATE category SET scan_bias_t_flag = 1") }
        let data = try export(from: source)

        let target = try makeDB(emptied: true)
        let importer = ShareImporter(db: target)
        let plan = try importer.makePlan(from: data)
        XCTAssertEqual(plan.identicalCount, 0)
        XCTAssertEqual(plan.conflictCount, 0)
        XCTAssertGreaterThan(plan.biasTRequested, 0)

        let summary = try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(summary.favoritesAdded, try favorites(source).count)
        XCTAssertEqual(try favorites(target).count, try favorites(source).count)
        XCTAssertEqual(try categories(target).count, try categories(source).count)
        XCTAssertEqual(try linkCount(target), try linkCount(source))
        XCTAssertTrue(try favorites(target).allSatisfy { $0.biasTFlag == 0 && $0.usbDeviceString.isEmpty })
        XCTAssertTrue(try categories(target).allSatisfy { $0.scanBiasTFlag == 0 && $0.scanUsbDeviceString.isEmpty })
    }

    // MARK: Collisions

    func testReimportingTheSameFileChangesNothing() throws {
        let db = try makeDB()
        let data = try export(from: db)
        let before = (try favorites(db).count, try categories(db).count, try linkCount(db))

        let importer = ShareImporter(db: db)
        let plan = try importer.makePlan(from: data)
        XCTAssertEqual(plan.newCount, 0)
        XCTAssertEqual(plan.conflictCount, 0)
        XCTAssertEqual(plan.identicalCount, before.0)
        XCTAssertTrue(plan.categories.allSatisfy { $0.status == .identical })

        let summary = try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(summary, ShareImportSummary())
        XCTAssertEqual(try favorites(db).count, before.0)
        XCTAssertEqual(try categories(db).count, before.1)
        XCTAssertEqual(try linkCount(db), before.2)
    }

    /// Their file names 88.3 "KABF 88.3 Little Rock"; mine has renamed it.
    private func conflictSetup() throws -> (db: DatabaseQueue, plan: ShareImportPlan, importer: ShareImporter) {
        let source = try makeDB()
        let data = try export(from: source)
        let mine = try makeDB()
        try mine.write { try $0.execute(sql: "UPDATE frequency SET station_name = 'Jazz 88.3', squelch_level = 3 WHERE frequency = 88300000") }
        let importer = ShareImporter(db: mine)
        return (mine, try importer.makePlan(from: data), importer)
    }

    func testConflictDefaultsToKeepBothAndNeverOverwrites() throws {
        let (db, plan, importer) = try conflictSetup()
        let conflict = try XCTUnwrap(plan.favorites.first { $0.shared.frequency == 88_300_000 })
        guard case .differs(let fields) = conflict.status else { return XCTFail("expected a conflict") }
        XCTAssertTrue(fields.contains("name"))
        XCTAssertEqual(conflict.action, .keepBoth)
        XCTAssertEqual(conflict.existingName, "Jazz 88.3")

        let before = try favorites(db).count
        try importer.apply(plan, backupDirectory: nil)
        let after = try favorites(db)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first { $0.stationName == "Jazz 88.3" }?.squelchLevel, 3, "mine must be untouched")
        XCTAssertNotNil(after.first { $0.stationName == "KABF 88.3 Little Rock" })
    }

    func testTakeTheirsOverwritesOnlyThatFavorite() throws {
        var (db, plan, importer) = try conflictSetup()
        let i = try XCTUnwrap(plan.favorites.firstIndex { $0.shared.frequency == 88_300_000 })
        plan.favorites[i].action = .takeTheirs
        let before = try favorites(db).count
        let summary = try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(summary.favoritesUpdated, 1)
        XCTAssertEqual(try favorites(db).count, before)
        let f = try XCTUnwrap(try favorites(db).first { $0.frequency == 88_300_000 })
        XCTAssertEqual(f.stationName, "KABF 88.3 Little Rock")
        XCTAssertEqual(f.squelchLevel, 0)
    }

    func testKeepMineLeavesExistingFavoriteAlone() throws {
        var (db, plan, importer) = try conflictSetup()
        let i = try XCTUnwrap(plan.favorites.firstIndex { $0.shared.frequency == 88_300_000 })
        plan.favorites[i].action = .keepMine
        let before = try favorites(db).count
        try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(try favorites(db).count, before)
        XCTAssertEqual(try favorites(db).first { $0.frequency == 88_300_000 }?.stationName, "Jazz 88.3")
    }

    func testCategoryMergeKeepsMySettingsAndReplaceUsesTheirs() throws {
        let source = try makeDB()
        let data = try export(from: source)
        let mine = try makeDB()
        try mine.write { try $0.execute(sql: "UPDATE category SET scan_squelch_level = 77 WHERE category_name = 'Aviation'") }
        let importer = ShareImporter(db: mine)

        var plan = try importer.makePlan(from: data)
        let i = try XCTUnwrap(plan.categories.firstIndex { $0.shared.name == "Aviation" })
        guard case .differs(let fields) = plan.categories[i].status else { return XCTFail("expected differing settings") }
        XCTAssertEqual(fields, ["squelch level"])
        XCTAssertEqual(plan.categories[i].action, .merge, "default must not overwrite")

        try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(try categories(mine).first { $0.categoryName == "Aviation" }?.scanSquelchLevel, 77)

        plan.categories[i].action = .replaceSettings
        try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(try categories(mine).first { $0.categoryName == "Aviation" }?.scanSquelchLevel, 90)
    }

    func testCategoryKeepBothCreatesRenamedCopyWithItsFavoritesLinked() throws {
        let source = try makeDB()
        let data = try export(from: source)
        let mine = try makeDB()
        try mine.write { try $0.execute(sql: "UPDATE category SET scan_squelch_level = 77 WHERE category_name = 'Aviation'") }
        let importer = ShareImporter(db: mine)
        var plan = try importer.makePlan(from: data)
        let i = try XCTUnwrap(plan.categories.firstIndex { $0.shared.name == "Aviation" })
        plan.categories[i].action = .keepBoth
        let linksBefore = try linkCount(mine)
        try importer.apply(plan, backupDirectory: nil)
        let copy = try XCTUnwrap(try categories(mine).first { $0.categoryName == "Aviation (imported)" })
        let linked = try mine.read { try FreqCat.filter(Column("cat_id") == copy.id).fetchCount($0) }
        XCTAssertGreaterThan(linked, 0)
        XCTAssertGreaterThan(try linkCount(mine), linksBefore)
    }

    func testMergeOnlyAddsLinksAndNeverRemovesThem() throws {
        let source = try makeDB()
        let data = try export(from: source)
        let mine = try makeDB()
        try mine.write { try $0.execute(sql: "INSERT INTO category (category_name) VALUES ('Mine')") }
        let mineID = try XCTUnwrap(try categories(mine).first { $0.categoryName == "Mine" }?.id)
        let someFav = try XCTUnwrap(try favorites(mine).first?.id)
        try mine.write { try $0.execute(sql: "INSERT INTO freq_cat (freq_id, cat_id) VALUES (?, ?)", arguments: [someFav, mineID]) }
        let importer = ShareImporter(db: mine)
        try importer.apply(try importer.makePlan(from: data), backupDirectory: nil)
        XCTAssertTrue(try mine.read { try FreqCat.filter(Column("cat_id") == mineID).fetchCount($0) } == 1)
    }

    func testSkippedCategoryDropsItsLinksButKeepsTheFavorites() throws {
        let source = try makeDB()
        let data = try export(from: source)
        let mine = try makeDB(emptied: true)
        let importer = ShareImporter(db: mine)
        var plan = try importer.makePlan(from: data)
        for i in plan.categories.indices { plan.categories[i].action = .skip }
        try importer.apply(plan, backupDirectory: nil)
        XCTAssertEqual(try categories(mine).count, 0)
        XCTAssertEqual(try linkCount(mine), 0)
        XCTAssertEqual(try favorites(mine).count, try favorites(source).count)
    }

    func testApplyMakesABackupFirst() throws {
        let db = try makeDB()
        let data = try export(from: db)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-backup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let importer = ShareImporter(db: db)
        let summary = try importer.apply(try importer.makePlan(from: data), backupDirectory: dir)
        let backup = try XCTUnwrap(summary.backupURL)
        let copy = try DatabaseQueue(path: backup.path)
        XCTAssertEqual(try copy.read { try Frequency.fetchCount($0) }, try favorites(db).count)
    }

    // MARK: Validation

    private func mutatedFile(_ change: (inout ShareFile) -> Void) throws -> Data {
        let source = try makeDB()
        var file = try ShareExporter(db: source).makeFile(try ShareExporter(db: source).everything())
        change(&file)
        return try ShareExporter.encode(file)
    }

    func testInvalidFavoritesAreRejectedWithReasonsAndOthersStillImport() throws {
        let data = try mutatedFile { file in
            file.favorites[0].modulation = "warp-drive"
            file.favorites[1].frequency = -5
            file.favorites[2].options = "dc; rm -rf ~"
            file.favorites[3].audioOutputFilter = "vol 1 $(reboot)"
            file.favorites[4].sampleRate = 0
            file.favorites[5].stationName = "  \u{0007} "
        }
        let total = try favorites(try makeDB()).count
        let plan = try ShareImporter(db: try makeDB(emptied: true)).makePlan(from: data)
        XCTAssertEqual(plan.rejected.count, 6, "\(plan.rejected)")
        XCTAssertEqual(plan.favorites.count, total - 6)
    }

    func testHostileNamesAreSanitizedNotRejected() {
        XCTAssertEqual(ShareValidator.cleanName("  KUAR\u{0000} 89.1\n"), "KUAR 89.1")
        XCTAssertEqual(ShareValidator.cleanName(String(repeating: "x", count: 500))?.count, ShareValidator.maxNameLength)
        XCTAssertNil(ShareValidator.cleanName("   "))
    }

    func testRejectsWrongFormatNonJSONAndNewerVersions() throws {
        XCTAssertThrowsError(try ShareValidator.decode(Data("hello".utf8)))
        XCTAssertThrowsError(try ShareValidator.decode(Data(#"{"format":"something-else"}"#.utf8)))
        let newer = try mutatedFile { $0.version = ShareFile.currentVersion + 1 }
        XCTAssertThrowsError(try ShareValidator.decode(newer)) { error in
            guard case ShareValidator.FileError.newerVersion = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ShareValidator.decode(Data(count: ShareValidator.maxFileBytes + 1)))
    }

    func testDuplicatesInsideOneFileAreCollapsed() throws {
        let data = try mutatedFile { $0.favorites.append($0.favorites[0]) }
        let plan = try ShareImporter(db: try makeDB(emptied: true)).makePlan(from: data)
        XCTAssertEqual(plan.rejected.count, 1)
        XCTAssertEqual(plan.favorites.count, try favorites(try makeDB()).count)
    }
}
