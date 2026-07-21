//
//  Item.swift
//  LimitBreak
//
//  Created by Daniel Flores on 7/20/26.
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
