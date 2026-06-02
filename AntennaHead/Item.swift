//
//  Item.swift
//  AntennaHead
//
//  Created by Douglas Ward on 6/1/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
