//
//  ShortcutFeedback.swift
//  ClaudeIsland
//
//  Visual and audio feedback when a keyboard shortcut fires
//

import AppKit
import Combine

enum ShortcutAction {
    case approve
    case deny
}

@MainActor
class ShortcutFeedback: ObservableObject {
    static let shared = ShortcutFeedback()

    @Published var activeFlash: ShortcutAction?

    private init() {}

    static func flash(_ action: ShortcutAction) {
        shared.activeFlash = action

        // Play a brief confirmation sound
        let soundName: String? = {
            switch action {
            case .approve: return "Tink"
            case .deny: return "Basso"
            }
        }()

        if let name = soundName {
            NSSound(named: name)?.play()
        }

        // Clear flash after brief display
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            shared.activeFlash = nil
        }
    }
}
