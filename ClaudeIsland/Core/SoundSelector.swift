//
//  SoundSelector.swift
//  ClaudeIsland
//
//  Manages sound selection state for the settings menu
//

import Foundation
import Observation

/// Manages sound selection state for the settings menu
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
final class SoundSelector {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = SoundSelector()

    // MARK: - Observable State

    var isPickerExpanded = false

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard self.isPickerExpanded else { return 0 }
        let totalOptions = NotificationSound.allCases.count
        let visibleOptions = min(totalOptions, maxVisibleOptions)
        return CGFloat(visibleOptions) * self.rowHeight + 8 // +8 for padding
    }

    // MARK: Private

    // MARK: - Constants

    /// Maximum number of sound options to show before scrolling
    private let maxVisibleOptions = 6

    /// Height per sound option row
    private let rowHeight: CGFloat = 32
}
