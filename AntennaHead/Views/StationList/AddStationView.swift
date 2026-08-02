import SwiftUI
import SharedLogging

struct AddStationView: View {
    var category: Category
    var onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var frequencyText = ""
    @State private var modulation: String = "fm"

    private var frequencyMHz: Double? { Double(frequencyText) }
    private var isValid: Bool { !name.isEmpty && frequencyMHz != nil }

    var body: some View {
        Form {
            TextField("Station Name", text: $name)
            HStack {
                TextField("Frequency (MHz)", text: $frequencyText)
                Picker("", selection: $modulation) {
                    ForEach(Frequency.modulationOptions, id: \.self) { mod in
                        Text(mod.uppercased()).tag(mod)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .navigationTitle("Add Station")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!isValid)
            }
        }
    }

    private func add() {
        guard let mhz = frequencyMHz, let categoryID = category.id else { return }
        var record = Frequency.prototype()
        record.stationName = name
        record.frequency = Int((mhz * 1_000_000).rounded())
        record.modulation = modulation
        do {
            let freqID = try SQLiteController.shared.insertFrequencyRecord(&record)
            try SQLiteController.shared.insertFreqCatRecord(forFrequencyID: freqID, categoryID: categoryID)
            onAdded()
            dismiss()
        } catch {
            // Surface to user once an error sheet exists; for now just log.
            LogStore.shared.log(.error, source: "AddStationView", "insert failed: \(error)")
        }
    }
}
