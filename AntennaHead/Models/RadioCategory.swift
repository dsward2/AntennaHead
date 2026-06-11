import SwiftData
import Foundation

@Model
final class RadioCategory {
    var name: String
    var icon: String
    var sortOrder: Int
    @Relationship(deleteRule: .cascade) var stations: [RadioStation]

    init(name: String, icon: String, sortOrder: Int) {
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.stations = []
    }
}

extension RadioCategory {
    static var defaults: [RadioCategory] {
        [
            RadioCategory(name: "FM Radio",      icon: "radio",              sortOrder: 0),
            RadioCategory(name: "Weather",        icon: "cloud.sun",          sortOrder: 1),
            RadioCategory(name: "Scanner",        icon: "antenna.radiowaves.left.and.right", sortOrder: 2),
            RadioCategory(name: "Aviation",       icon: "airplane",           sortOrder: 3),
            RadioCategory(name: "Custom",         icon: "slider.horizontal.3", sortOrder: 4),
        ]
    }
}
