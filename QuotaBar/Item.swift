//
//  Item.swift
//  QuotaBar
//
//  Created by Aidan on 2026/3/12.
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
