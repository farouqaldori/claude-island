//
//  SuppressionSelector.swift
//  ClaudeIsland
//
//  Manages sound suppression selection state for the settings menu
//

import Combine
import Foundation

@MainActor
class SuppressionSelector: ObservableObject {
    static let shared = SuppressionSelector()

    // MARK: - Published State

    @Published var isPickerExpanded: Bool = false

    // MARK: - Constants

    /// Number of suppression options (Never, When Focused, When Visible)
    private let optionCount = 3

    /// Height per option row (taller for descriptions)
    private let rowHeight: CGFloat = 44

    private init() {}

    // MARK: - Public API

    /// Extra height needed when picker is expanded
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return CGFloat(optionCount) * rowHeight + 8 // +8 for padding
    }
}
