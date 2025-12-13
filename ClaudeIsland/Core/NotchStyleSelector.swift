//
//  NotchStyleSelector.swift
//  ClaudeIsland
//
//  Manages notch style selection state for the settings menu
//

import Combine
import Foundation

@MainActor
class NotchStyleSelector: ObservableObject {
    static let shared = NotchStyleSelector()

    @Published var isPickerExpanded: Bool = false

    private let rowHeight: CGFloat = 40

    private init() {}

    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return CGFloat(NotchStyle.allCases.count) * rowHeight + 4
    }
}
