//
//  VoiceSelector.swift
//  ClaudeIsland
//
//  Manages voice selection state for the settings menu
//

import AVFoundation
import Combine
import Foundation

@MainActor
class VoiceSelector: ObservableObject {
    static let shared = VoiceSelector()

    // MARK: - Published State

    @Published var isPickerExpanded: Bool = false

    // MARK: - Constants

    /// Maximum number of voice options to show before scrolling
    private let maxVisibleOptions = 6

    /// Height per voice option row
    private let rowHeight: CGFloat = 32

    private init() {}

    // MARK: - Public API

    /// Extra height needed when picker is expanded (capped for scrolling)
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        // +1 for Default option, +1 for Disable row, +1 for divider
        let totalOptions = SpeechManager.availableVoices.count + 3
        let visibleOptions = min(totalOptions, maxVisibleOptions)
        return CGFloat(visibleOptions) * rowHeight + 8
    }
}
