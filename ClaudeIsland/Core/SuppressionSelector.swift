//
//  SuppressionSelector.swift
//  ClaudeIsland
//
//  Manages sound suppression selection state for the settings menu
//

import Foundation
import Observation

/// Manages sound suppression selection state for the settings menu
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
final class SuppressionSelector {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = SuppressionSelector()

    // MARK: - Observable State

    var isPickerExpanded = false

    // MARK: - Public API

    /// Extra height needed when picker is expanded
    var expandedPickerHeight: CGFloat {
        guard self.isPickerExpanded else { return 0 }
        let totalOptions = SoundSuppression.allCases.count
        return CGFloat(totalOptions) * self.rowHeight + 8 // +8 for padding
    }

    // MARK: Private

    // MARK: - Constants

    /// Height per suppression option row
    private let rowHeight: CGFloat = 44
}
