import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File > Import Tuning Data…: choose a share file, review what would be added
/// or changed, resolve any collisions, then import. Nothing is written until
/// "Import" is clicked, and the default for every collision is to leave the
/// existing data alone.
struct ShareImportView: View {
    @State private var plan: ShareImportPlan?
    @State private var fileName = ""
    @State private var error: String?
    @State private var summary: ShareImportSummary?
    @State private var confirming = false
    @State private var showRejected = false

    init(initialPlan: ShareImportPlan? = nil) {
        _plan = State(initialValue: initialPlan)
    }

    var body: some View {
        Group {
            if let summary {
                doneView(summary)
            } else if let planBinding = Binding($plan) {
                reviewView(planBinding)
            } else {
                startView
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: Start

    private var startView: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Import tuning data from an AntennaHead share file").font(.headline)
            Text("You'll see what would be added or changed before anything is written, and your existing favorites are never overwritten unless you choose to.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Choose File…") { chooseFile() }.keyboardShortcut(.defaultAction)
            if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 460) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFile() {
        error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an AntennaHead share file (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            plan = try ShareImporter().makePlan(from: data)
            fileName = url.lastPathComponent
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Review

    private func reviewView(_ plan: Binding<ShareImportPlan>) -> some View {
        VStack(spacing: 0) {
            header(plan.wrappedValue)
            Divider()
            List {
                if !plan.wrappedValue.categories.isEmpty {
                    Section("Categories") {
                        ForEach(plan.categories) { $item in categoryRow($item) }
                    }
                }
                Section("Favorites") {
                    ForEach(plan.favorites) { $item in favoriteRow($item) }
                }
            }
            Divider()
            HStack {
                Menu("Set all conflicts to…") {
                    Button("Keep mine") { setConflicts(plan, .keepMine) }
                    Button("Use theirs") { setConflicts(plan, .takeTheirs) }
                    Button("Keep both") { setConflicts(plan, .keepBoth) }
                }
                .disabled(plan.wrappedValue.conflictCount == 0)
                Spacer()
                Button("Choose Another File…") { self.plan = nil; chooseFile() }
                Button("Cancel") { self.plan = nil }
                Button("Import…") { confirming = true }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .confirmationDialog("Import into your AntennaHead data?", isPresented: $confirming) {
            Button("Import") { runImport(plan.wrappedValue) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup copy of your database is saved first, so you can go back if you change your mind.")
        }
    }

    private func header(_ plan: ShareImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.file.title ?? fileName).font(.title3.bold())
            if let region = plan.file.region { Text("Region: \(region)") }
            if let notes = plan.file.notes { Text(notes).foregroundStyle(.secondary) }
            Text("\(plan.newCount) new, \(plan.identicalCount) already in your list, \(plan.conflictCount) to resolve"
                 + " · \(plan.categories.count) categories")
                .foregroundStyle(.secondary)
            if plan.biasTRequested > 0 {
                Label("\(plan.biasTRequested) item(s) had bias-tee power on. They import with it off; turn it on yourself only if you have an antenna that needs it.",
                      systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !plan.rejected.isEmpty {
                DisclosureGroup("\(plan.rejected.count) item(s) can't be imported", isExpanded: $showRejected) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plan.rejected, id: \.self) { Text("• \($0)").font(.caption) }
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func categoryRow(_ item: Binding<CategoryImportItem>) -> some View {
        let v = item.wrappedValue
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(v.shared.name)
                switch v.status {
                case .new: Text("New category").font(.caption).foregroundStyle(.green)
                case .identical: Text("Already in your list").font(.caption).foregroundStyle(.secondary)
                case .differs(let f):
                    Text("You have a category with this name; scan settings differ: \(f.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Picker("", selection: item.action) {
                ForEach(v.allowedActions, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            .disabled(v.allowedActions.count < 2)
        }
    }

    private func favoriteRow(_ item: Binding<FavoriteImportItem>) -> some View {
        let v = item.wrappedValue
        let mhz = String(format: "%.3f MHz", Double(v.shared.frequency) / 1_000_000)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(v.shared.stationName)
                    Text(mhz + (v.shared.frequencyMode == 1 ? " scan" : "") + " · \(v.shared.modulation)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                switch v.status {
                case .new: Text("New").font(.caption).foregroundStyle(.green)
                case .identical: Text("Already in your list").font(.caption).foregroundStyle(.secondary)
                case .differs(let f):
                    Text("Same tuning as your \"\(v.existingName ?? "favorite")\"; differs: \(f.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !v.shared.categories.isEmpty {
                    Text("In: \(v.shared.categories.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: item.action) {
                ForEach(v.allowedActions, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            .disabled(v.allowedActions.count < 2)
        }
    }

    private func setConflicts(_ plan: Binding<ShareImportPlan>, _ action: FavoriteImportItem.Action) {
        for i in plan.wrappedValue.favorites.indices {
            if case .differs = plan.wrappedValue.favorites[i].status { plan.wrappedValue.favorites[i].action = action }
        }
    }

    private func runImport(_ plan: ShareImportPlan) {
        do {
            summary = try ShareImporter().apply(plan)
        } catch {
            self.error = "Import failed: \(error.localizedDescription) Your data was not changed."
            self.plan = nil
        }
    }

    // MARK: Done

    private func doneView(_ s: ShareImportSummary) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("Import complete").font(.headline)
            Text("Added \(s.favoritesAdded) favorites and \(s.categoriesAdded) categories; updated \(s.favoritesUpdated) favorites and \(s.categoriesUpdated) categories; \(s.linksAdded) category links added.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Text("Reload the web view (⌘R) if you have the AntennaHead web UI open.").font(.callout).foregroundStyle(.secondary)
            HStack {
                if let backup = s.backupURL {
                    Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                }
                Button("Import Another File…") { summary = nil; plan = nil; chooseFile() }
                Button("Done") { summary = nil; plan = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
