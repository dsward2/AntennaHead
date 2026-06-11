import SwiftUI

struct StationListView: View {
    var category: Category?
    @Binding var selectedStation: Frequency?
    @Binding var refreshID: UUID
    @State private var showAddStation = false
    @State private var searchText = ""
    @State private var frequencies: [Frequency] = []

    var filteredFrequencies: [Frequency] {
        frequencies.filter {
            searchText.isEmpty
                || $0.stationName.localizedCaseInsensitiveContains(searchText)
                || $0.formattedFrequency.contains(searchText)
        }
    }

    var body: some View {
        Group {
            if category == nil {
                ContentUnavailableView("Select a Category", systemImage: "sidebar.left")
            } else if filteredFrequencies.isEmpty {
                ContentUnavailableView {
                    Label("No Stations", systemImage: "radio")
                } description: {
                    Text("Add a station to get started.")
                } actions: {
                    Button("Add Station") { showAddStation = true }
                }
            } else {
                List(filteredFrequencies, selection: $selectedStation) { frequency in
                    StationRowView(frequency: frequency)
                        .tag(frequency)
                }
                .searchable(text: $searchText, prompt: "Search stations")
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .navigationTitle(category?.categoryName ?? "Stations")
        .toolbar {
            if category != nil {
                Button("Add Station", systemImage: "plus") {
                    showAddStation = true
                }
            }
        }
        .sheet(isPresented: $showAddStation) {
            if let category {
                AddStationView(category: category) {
                    refreshID = UUID()
                }
            }
        }
        .task(id: refreshID) { reload() }
        .onChange(of: category) { _, _ in reload() }
    }

    private func reload() {
        guard let category, let id = category.id else {
            frequencies = []
            return
        }
        frequencies = (try? SQLiteController.shared.allFrequencyRecords(forCategoryID: id)) ?? []
    }
}

struct StationRowView: View {
    var frequency: Frequency

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(frequency.stationName)
                    .font(.headline)
                Text(frequency.formattedFrequency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(frequency.modulation.uppercased())
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
