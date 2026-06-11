import SwiftData
import Foundation

@Model
final class RadioStation {
    var name: String
    var frequency: Double       // MHz
    var modulation: Modulation
    var isFavorite: Bool
    var notes: String
    var category: RadioCategory?

    init(name: String, frequency: Double, modulation: Modulation = .fm, category: RadioCategory? = nil) {
        self.name = name
        self.frequency = frequency
        self.modulation = modulation
        self.isFavorite = false
        self.notes = ""
        self.category = category
    }

    enum Modulation: String, Codable, CaseIterable {
        case fm = "FM"
        case am = "AM"
        case wfm = "WFM"
        case nfm = "NFM"
    }

    var formattedFrequency: String {
        String(format: "%.3f MHz", frequency)
    }
}
