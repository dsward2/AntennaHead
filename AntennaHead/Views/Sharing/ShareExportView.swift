import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File > Export Tuning Data…: pick categories and/or favorites, add an optional
/// description (e.g. the region they apply to), and save a share file.
struct ShareExportView: View {
    @State private var categories: [Category] = []
    @State private var favorites: [Frequency] = []
    @State private var links: [FreqCat] = []
    @State private var selectedCategories: Set<Int64> = []
    @State private var selectedFavorites: Set<Int64> = []
    @State private var search = ""
    @State private var title = ""
    @State private var region = ""
    @State private var notes = ""
    @State private var message: String?
    @State private var loadError: String?

    /// Favorites that ride along because one of their categories is selected.
    private var favoritesViaCategories: Set<Int64> {
        Set(links.filter { selectedCategories.contains($0.catId) }.map(\.freqId))
    }
    private var effectiveFavoriteCount: Int { selectedFavorites.union(favoritesViaCategories).count }
    private var nothingSelected: Bool { selectedCategories.isEmpty && effectiveFavoriteCount == 0 }

    private var visibleFavorites: [Frequency] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return favorites }
        return favorites.filter { $0.stationName.lowercased().contains(q) || $0.formattedFrequency.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                categoryColumn.frame(minWidth: 220, idealWidth: 240)
                favoriteColumn.frame(minWidth: 320)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 520)
        .task { load() }
    }

    private var categoryColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                Button("All") { selectedCategories = Set(categories.compactMap(\.id)) }
                Button("None") { selectedCategories = [] }
            }
            Text("A category is shared with its scan settings and all of its favorites.")
                .font(.caption).foregroundStyle(.secondary)
            List(categories) { c in
                if let id = c.id {
                    Toggle(isOn: Binding(get: { selectedCategories.contains(id) },
                                         set: { if $0 { selectedCategories.insert(id) } else { selectedCategories.remove(id) } })) {
                        HStack {
                            Text(c.categoryName)
                            Spacer()
                            Text("\(links.filter { $0.catId == id }.count)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var favoriteColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Favorites").font(.headline)
                Spacer()
                Button("All") { selectedFavorites = Set(favorites.compactMap(\.id)) }
                Button("None") { selectedFavorites = [] }
            }
            TextField("Search favorites", text: $search).textFieldStyle(.roundedBorder)
            List(visibleFavorites) { f in
                if let id = f.id {
                    let viaCategory = favoritesViaCategories.contains(id)
                    Toggle(isOn: Binding(get: { viaCategory || selectedFavorites.contains(id) },
                                         set: { if $0 { selectedFavorites.insert(id) } else { selectedFavorites.remove(id) } })) {
                        HStack {
                            Text(f.stationName)
                            Spacer()
                            Text(f.formattedFrequency).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .disabled(viaCategory)
                    .help(viaCategory ? "Included because one of its categories is selected" : "")
                }
            }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Title").gridColumnAlignment(.trailing)
                    TextField("Optional, e.g. \"Central Arkansas favorites\"", text: $title)
                }
                GridRow {
                    Text("Region")
                    TextField("Optional, where these frequencies work, e.g. \"Little Rock, AR\"", text: $region)
                }
                GridRow {
                    Text("Notes")
                    TextField("Optional", text: $notes)
                }
            }
            HStack {
                Text(nothingSelected ? "Nothing selected."
                     : "\(selectedCategories.count) categories and \(effectiveFavoriteCount) favorites will be exported.")
                    .foregroundStyle(.secondary)
                Spacer()
                if let loadError { Text(loadError).foregroundStyle(.red) }
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nothingSelected)
            }
            Text("Device serial numbers are never included, and the bias-tee setting is included for information only (it always imports as off).")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout) }
        }
        .padding(12)
    }

    private func load() {
        do {
            let s = SQLiteController.shared
            categories = try s.allCategoryRecords().sorted { $0.categoryName.localizedCaseInsensitiveCompare($1.categoryName) == .orderedAscending }
            favorites = try s.allFrequencyRecords()
            links = try s.allFreqCatRecords()
            loadError = nil
        } catch {
            loadError = "Couldn't read the database: \(error.localizedDescription)"
        }
    }

    private func export() {
        do {
            let exporter = ShareExporter()
            let file = try exporter.makeFile(.init(categoryIDs: selectedCategories, favoriteIDs: selectedFavorites),
                                             metadata: .init(title: title, region: region, notes: notes))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = ShareExporter.suggestedFileName(for: file)
            panel.message = "Save a file you can send to other AntennaHead users."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ShareExporter.encode(file).write(to: url, options: .atomic)
            message = "Exported \(file.categories.count) categories and \(file.favorites.count) favorites to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}
