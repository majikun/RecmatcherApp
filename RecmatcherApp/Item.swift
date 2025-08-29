//
//  Item.swift
//  RecmatcherApp
//
//  Created by JakeMa@max on 2025/8/29.
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
