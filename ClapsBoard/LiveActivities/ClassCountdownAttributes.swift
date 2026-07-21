//
//  ClassCountdownAttributes.swift
//  ClapsBoard
//
//  Shared Live Activity model for the upcoming class countdown.
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct ClassCountdownAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var scheduledStart: Date
    }

    var classId: UUID
}
