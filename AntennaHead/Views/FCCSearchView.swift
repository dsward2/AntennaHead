import SwiftUI

struct FCCSearchView: View {
    @State private var zipCode = ""
    @State private var radiusMiles = 25.0
    @State private var results: [FCCStation] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Search Parameters") {
                    TextField("ZIP Code", text: $zipCode)
                        .textContentType(.postalCode)
                    HStack {
                        Text("Radius")
                        Slider(value: $radiusMiles, in: 5...100, step: 5)
                        Text("\(Int(radiusMiles)) mi")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                Section {
                    Button("Search FCC Database") {
                        Task { await search() }
                    }
                    .disabled(zipCode.count < 5 || isSearching)
                }
                if !results.isEmpty {
                    Section("Results (\(results.count))") {
                        ForEach(results) { station in
                            FCCStationRowView(station: station)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("FCC Station Search")
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        // FCC API integration will go here
        results = FCCStation.placeholders
    }
}

struct FCCStationRowView: View {
    var station: FCCStation

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.callSign).font(.headline)
                Text(station.city).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(station.formattedFrequency)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Add", systemImage: "plus.circle") {}
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

struct FCCStation: Identifiable {
    let id = UUID()
    var callSign: String
    var frequency: Double
    var city: String

    var formattedFrequency: String { String(format: "%.1f MHz", frequency) }

    static let placeholders: [FCCStation] = [
        FCCStation(callSign: "WBEZ", frequency: 91.5, city: "Chicago, IL"),
        FCCStation(callSign: "WXRT", frequency: 93.1, city: "Chicago, IL"),
    ]
}
