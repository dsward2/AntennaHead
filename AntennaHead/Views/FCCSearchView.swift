import SwiftUI

/// FCC FM-station database search, ported from LocalRadio's FCC Search window:
/// enter a 5-digit ZIP code and radius, search the FCC FM Query service, then
/// Listen to a result or add it to Favorites (with a replace/add/cancel prompt
/// when a favorite already exists for that frequency).
struct FCCSearchView: View {
    /// Posted when the Listen button is clicked; ContentView owns the
    /// SDRController and starts the tune. userInfo: frequencyHz, sampleRate,
    /// tunerGain, stereo (the FCC window is a separate scene without the controller).
    static let listenNotification = Notification.Name("FCCSearchView.listen")

    @State private var zipCode = ""
    @State private var radius = 50
    @State private var radiusUnits: RadiusUnits = .miles
    @State private var sampleRate = 170_000
    @State private var tunerGain = 49.6
    @State private var stereo = true

    @State private var results: [FCCStationRecord] = []
    @State private var selection: FCCStationRecord.ID?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showingReplaceAlert = false

    private enum RadiusUnits: String, CaseIterable {
        case miles, km
    }

    private var selectedStation: FCCStationRecord? {
        results.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Search With 5-Digit ZIP Code") {
                    TextField("ZIP Code:", text: $zipCode)
                        .textContentType(.postalCode)
                    LabeledContent("Radius:") {
                        TextField("Radius", value: $radius, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Picker("Units", selection: $radiusUnits) {
                            ForEach(RadiusUnits.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Picker("Sample Rate:", selection: $sampleRate) {
                        Text("85000").tag(85_000)
                        Text("170000").tag(170_000)
                    }
                    Picker("Tuner Gain:", selection: $tunerGain) {
                        Text("12.5").tag(12.5)
                        Text("25.4").tag(25.4)
                        Text("49.6").tag(49.6)
                    }
                    Toggle("Stereo", isOn: $stereo)
                }
                Section {
                    HStack {
                        Button("Search") {
                            Task { await search() }
                        }
                        .disabled(zipCode.count != 5 || isSearching)
                        if isSearching {
                            ProgressView().controlSize(.small)
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 230)

            Table(results, selection: $selection) {
                TableColumn("Frequency") { Text($0.frequencyText).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Station", value: \.callSign)
                    .width(min: 60, ideal: 80)
                TableColumn("Location") { Text("\($0.city), \($0.state) - \($0.licensee)") }
                TableColumn("Distance") { station in
                    Text(radiusUnits == .miles ? "\(station.distanceMiles) mi" : "\(station.distanceKm) km")
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Direction", value: \.compassDirection)
                    .width(min: 60, ideal: 70)
                TableColumn("ERP", value: \.erp)
                    .width(min: 60, ideal: 80)
            }
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button("Add to Favorites") { addToFavoritesTapped() }
                    .disabled(selectedStation == nil)
                Spacer()
                Button("Listen") { listen() }
                    .disabled(selectedStation == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle("FCC Database Search")
        .frame(minWidth: 640, minHeight: 520)
        .alert("Existing record found for this frequency", isPresented: $showingReplaceAlert) {
            Button("Replace Existing Record") { saveFavorite(replacingExisting: true) }
            Button("Add New Record") { saveFavorite(replacingExisting: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can replace the existing frequency record, or add a new record "
                 + "with the same frequency, or cancel this operation.")
        }
    }

    private func search() async {
        errorMessage = nil
        guard let zip = Int(zipCode), (10_000...99_999).contains(zip) else {
            errorMessage = "Enter a 5-digit ZIP code."
            return
        }
        guard let coordinate = FCCSearch.coordinate(forZIPCode: zip) else {
            errorMessage = FCCSearch.SearchError.unknownZIPCode.localizedDescription
            return
        }
        // The fmq service takes kilometers.
        let radiusKm = radiusUnits == .miles ? Int(Double(radius) * 1.60934) : radius

        isSearching = true
        defer { isSearching = false }
        do {
            results = try await FCCSearch.search(latitude: coordinate.lat,
                                                 longitude: coordinate.lon,
                                                 radiusKm: radiusKm)
            selection = nil
            if results.isEmpty { errorMessage = "No FM stations found." }
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }

    /// Tunes the radio to the selected station (via ContentView, which owns
    /// the SDRController).
    private func listen() {
        guard let station = selectedStation, station.frequencyHz > 0 else { return }
        NotificationCenter.default.post(name: Self.listenNotification, object: nil, userInfo: [
            "frequencyHz": station.frequencyHz,
            "sampleRate": sampleRate,
            "tunerGain": tunerGain,
            "stereo": stereo
        ])
    }

    private func addToFavoritesTapped() {
        guard let station = selectedStation, station.frequencyHz > 0 else { return }
        let existing = (try? SQLiteController.shared.frequencyRecord(forFrequency: station.frequencyHz)) ?? nil
        if existing != nil {
            showingReplaceAlert = true
        } else {
            saveFavorite(replacingExisting: false)
        }
    }

    /// Inserts (or updates) a favorite from the selected search result, using
    /// LocalRadio's FM-broadcast defaults for the pipeline fields.
    private func saveFavorite(replacingExisting: Bool) {
        guard let station = selectedStation, station.frequencyHz > 0 else { return }

        var record: Frequency
        if replacingExisting,
           let existing = (try? SQLiteController.shared.frequencyRecord(forFrequency: station.frequencyHz)) ?? nil {
            record = existing
        } else {
            record = Frequency.prototype()
        }

        record.stationName = "\(station.callSign) - \(station.city)"
        record.frequency = station.frequencyHz
        record.sampleRate = sampleRate
        record.tunerGain = tunerGain
        record.modulation = "wfm"
        record.stereoFlag = stereo
        record.audioOutputFilter = "vol 1"
        record.oversampling = sampleRate > 85_000 ? 2 : 4

        if record.id != nil {
            try? SQLiteController.shared.updateFrequencyRecord(record)
        } else {
            _ = try? SQLiteController.shared.insertFrequencyRecord(&record)
        }
    }
}
