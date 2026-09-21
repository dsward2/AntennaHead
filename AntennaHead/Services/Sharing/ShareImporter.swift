import Foundation
import GRDB

// MARK: - Plan

/// One category from a share file, compared with what's already in the database.
struct CategoryImportItem: Identifiable, Equatable {
    enum Status: Equatable { case new, identical, differs([String]) }
    enum Action: String, CaseIterable, Equatable {
        case add = "Add"
        case merge = "Merge into mine"          // add the file's favorites, keep my settings
        case replaceSettings = "Use their settings"
        case keepBoth = "Keep both"
        case skip = "Don't import"
    }

    let id: String   // unique across categories and favorites (they share one List)
    let shared: SharedCategory
    let existingID: Int64?
    let status: Status
    var action: Action

    var allowedActions: [Action] {
        switch status {
        case .new: [.add, .skip]
        case .identical: [.merge, .skip]
        case .differs: [.merge, .replaceSettings, .keepBoth, .skip]
        }
    }
}

/// One favorite from a share file, compared with what's already in the database.
struct FavoriteImportItem: Identifiable, Equatable {
    enum Status: Equatable { case new, identical, differs([String]) }
    enum Action: String, CaseIterable, Equatable {
        case add = "Add"
        case keepMine = "Keep mine"
        case takeTheirs = "Use theirs"
        case keepBoth = "Keep both"
        case skip = "Don't import"
    }

    let id: String   // unique across categories and favorites (they share one List)
    let shared: SharedFavorite
    let existingID: Int64?
    let existingName: String?
    let status: Status
    var action: Action

    var allowedActions: [Action] {
        switch status {
        case .new: [.add, .skip]
        case .identical: [.keepMine]
        case .differs: [.keepMine, .takeTheirs, .keepBoth]
        }
    }
}

struct ShareImportPlan: Equatable {
    var file: ShareFile
    var categories: [CategoryImportItem]
    var favorites: [FavoriteImportItem]
    /// Human-readable reasons individual records were left out (invalid data, duplicates).
    var rejected: [String]
    /// Favorites/categories the sender had bias-T on for. They import with it off.
    var biasTRequested: Int

    var newCount: Int { favorites.filter { $0.status == .new }.count }
    var identicalCount: Int { favorites.filter { $0.status == .identical }.count }
    var conflictCount: Int { favorites.filter { if case .differs = $0.status { true } else { false } }.count }
}

struct ShareImportSummary: Equatable {
    var categoriesAdded = 0, categoriesUpdated = 0
    var favoritesAdded = 0, favoritesUpdated = 0
    var linksAdded = 0
    var backupURL: URL?
}

// MARK: - Importer

struct ShareImporter {
    let db: DatabaseQueue

    init(db: DatabaseQueue = AppDatabase.shared.dbQueue) { self.db = db }

    static let didImportNotification = Notification.Name("AntennaHeadShareDidImport")

    /// Reads and validates a file and compares it with the database. Nothing is written.
    func makePlan(from data: Data) throws -> ShareImportPlan {
        let file = try ShareValidator.decode(data)
        return try makePlan(from: file)
    }

    func makePlan(from file: ShareFile) throws -> ShareImportPlan {
        let (existingCategories, existingFavorites) = try db.read { db in
            (try Category.fetchAll(db), try Frequency.fetchAll(db))
        }
        var rejected: [String] = []
        var biasT = 0

        // Categories
        let categoryByName = Dictionary(existingCategories.map { ($0.categoryName.lowercased(), $0) },
                                        uniquingKeysWith: { first, _ in first })
        var seenCategories = Set<String>()
        var categoryItems: [CategoryImportItem] = []
        for shared in file.categories {
            switch ShareValidator.validated(shared) {
            case .failure(let r):
                rejected.append("Category \"\(shared.name)\" \(r.reason)."); continue
            case .success(let c):
                guard seenCategories.insert(c.name.lowercased()).inserted else {
                    rejected.append("Category \"\(c.name)\" appears more than once in the file; the first was used."); continue
                }
                if c.scanBiasTFlag != 0 { biasT += 1 }
                let item: CategoryImportItem
                if let existing = categoryByName[c.name.lowercased()] {
                    let diffs = c.differences(from: SharedCategory(existing))
                    item = CategoryImportItem(id: "c\(categoryItems.count)", shared: c, existingID: existing.id,
                                              status: diffs.isEmpty ? .identical : .differs(diffs), action: .merge)
                } else {
                    item = CategoryImportItem(id: "c\(categoryItems.count)", shared: c, existingID: nil, status: .new, action: .add)
                }
                categoryItems.append(item)
            }
        }

        // Favorites
        var existingByKey: [String: Frequency] = [:]
        for f in existingFavorites {
            let key = SharedFavorite(f, categoryNames: []).tuningKey
            if existingByKey[key] == nil { existingByKey[key] = f }
        }
        var seenInFile = Set<String>()
        var favoriteItems: [FavoriteImportItem] = []
        for shared in file.favorites {
            switch ShareValidator.validated(shared) {
            case .failure(let r):
                rejected.append("Favorite \"\(shared.stationName)\" \(r.reason)."); continue
            case .success(let f):
                guard seenInFile.insert(f.tuningKey + "|" + f.stationName.lowercased()).inserted else {
                    rejected.append("Favorite \"\(f.stationName)\" (\(f.frequency) Hz) appears more than once in the file; the first was used."); continue
                }
                if f.biasTFlag != 0 { biasT += 1 }
                let item: FavoriteImportItem
                if let existing = existingByKey[f.tuningKey] {
                    let diffs = f.differences(from: SharedFavorite(existing, categoryNames: []))
                    item = FavoriteImportItem(id: "f\(favoriteItems.count)", shared: f, existingID: existing.id,
                                              existingName: existing.stationName,
                                              status: diffs.isEmpty ? .identical : .differs(diffs),
                                              action: diffs.isEmpty ? .keepMine : .keepBoth)
                } else {
                    item = FavoriteImportItem(id: "f\(favoriteItems.count)", shared: f, existingID: nil,
                                              existingName: nil, status: .new, action: .add)
                }
                favoriteItems.append(item)
            }
        }
        return ShareImportPlan(file: file, categories: categoryItems, favorites: favoriteItems,
                               rejected: rejected, biasTRequested: biasT)
    }

    // MARK: Apply

    /// Applies the plan in one transaction, after saving a backup copy of the
    /// database into `backupDirectory` (skipped when nil, e.g. in tests).
    @discardableResult
    func apply(_ plan: ShareImportPlan, backupDirectory: URL? = ShareImporter.defaultBackupDirectory) throws -> ShareImportSummary {
        var summary = ShareImportSummary()
        if let dir = backupDirectory { summary.backupURL = try makeBackup(in: dir) }

        try db.write { db in
            var categoryNames = Set(try Category.fetchAll(db).map { $0.categoryName.lowercased() })
            var favoriteNames = Set(try Frequency.fetchAll(db).map { $0.stationName.lowercased() })
            var categoryIDByName: [String: Int64] = [:]

            for item in plan.categories {
                let key = item.shared.name.lowercased()
                switch item.action {
                case .add:
                    var rec = item.shared.makeRecord(named: item.shared.name)
                    try rec.insert(db)
                    categoryIDByName[key] = rec.id; categoryNames.insert(key); summary.categoriesAdded += 1
                case .merge:
                    if let id = item.existingID { categoryIDByName[key] = id }
                case .replaceSettings:
                    if let id = item.existingID, var rec = try Category.fetchOne(db, key: id) {
                        item.shared.apply(to: &rec)
                        try rec.update(db)
                        categoryIDByName[key] = id; summary.categoriesUpdated += 1
                    }
                case .keepBoth:
                    let name = Self.uniqueName(item.shared.name, taken: categoryNames)
                    var rec = item.shared.makeRecord(named: name)
                    try rec.insert(db)
                    categoryIDByName[key] = rec.id; categoryNames.insert(name.lowercased()); summary.categoriesAdded += 1
                case .skip:
                    break
                }
            }
            // A favorite may name a category that isn't in the file's category
            // list; link it to a local category of that name if there is one.
            func categoryID(named name: String) throws -> Int64? {
                let key = name.lowercased()
                if let id = categoryIDByName[key] { return id }
                if plan.categories.contains(where: { $0.shared.name.lowercased() == key }) { return nil }  // explicitly skipped
                return try Category.filter(Column("category_name").collating(.nocase) == name).fetchOne(db)?.id
            }

            for item in plan.favorites {
                var freqID: Int64?
                switch item.action {
                case .add:
                    var rec = item.shared.makeRecord(named: item.shared.stationName)
                    try rec.insert(db)
                    freqID = rec.id; favoriteNames.insert(item.shared.stationName.lowercased()); summary.favoritesAdded += 1
                case .keepMine:
                    freqID = item.existingID
                case .takeTheirs:
                    if let id = item.existingID, var rec = try Frequency.fetchOne(db, key: id) {
                        item.shared.apply(to: &rec)
                        try rec.update(db)
                        freqID = id; summary.favoritesUpdated += 1
                    }
                case .keepBoth:
                    let name = favoriteNames.contains(item.shared.stationName.lowercased())
                        ? Self.uniqueName(item.shared.stationName, taken: favoriteNames) : item.shared.stationName
                    var rec = item.shared.makeRecord(named: name)
                    try rec.insert(db)
                    freqID = rec.id; favoriteNames.insert(name.lowercased()); summary.favoritesAdded += 1
                case .skip:
                    break
                }
                guard let freqID else { continue }
                for name in item.shared.categories {
                    guard let catID = try categoryID(named: name) else { continue }
                    let exists = try FreqCat.filter(Column("freq_id") == freqID && Column("cat_id") == catID).fetchCount(db) > 0
                    if !exists {
                        var link = FreqCat(id: nil, freqId: freqID, catId: catID)
                        try link.insert(db)
                        summary.linksAdded += 1
                    }
                }
            }
        }
        NotificationCenter.default.post(name: Self.didImportNotification, object: nil)
        return summary
    }

    /// "Name (imported)", then "Name (imported 2)", … — first one not in `taken`.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var candidate = "\(base) (imported)"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (imported \(n))"; n += 1
        }
        return candidate
    }

    // MARK: Backup

    static var defaultBackupDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AntennaHead/Backups", isDirectory: true)
    }

    private func makeBackup(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("AntennaHead-before-import-\(f.string(from: Date())).sqlite3")
        let destination = try DatabaseQueue(path: url.path)
        try db.backup(to: destination)
        // Keep the newest ten.
        let old = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.lastPathComponent.hasPrefix("AntennaHead-before-import-") && $0.pathExtension == "sqlite3" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(10)
        for u in old { try? FileManager.default.removeItem(at: u) }
        return url
    }
}
