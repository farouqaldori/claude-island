//
//  ClawdSelector.swift
//  ClaudeIsland
//
//  Manages Clawd customization state for the settings menu
//

import Foundation
import Observation

@Observable
final class ClawdSelector {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = ClawdSelector()

    // MARK: - Observable State

    var isColorPickerExpanded = false

    var expandedPickerHeight: CGFloat {
        guard self.isColorPickerExpanded else { return 0 }
        return 240
    }
}
