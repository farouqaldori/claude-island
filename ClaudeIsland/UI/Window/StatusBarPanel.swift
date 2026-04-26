//
//  StatusBarPanel.swift
//  ClaudeIsland
//
//  Custom NSPanel for status bar popup in fullscreen auto-hide menu bar scenarios
//

import AppKit

/// Floating panel for status bar content that stays in place when menu bar auto-hides
final class StatusBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent background, content view draws its own rounded corners and shadow
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Not movable, fixed position
        isMovable = false
        isMovableByWindowBackground = false

        // Across Spaces, overlay fullscreen apps, not in Cmd+` cycle
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // Slightly above mainMenu so panel stays visible when menu bar auto-hides
        // But below NotchPanel's mainMenu+3 to avoid conflict with Notch mode
        level = .mainMenu + 1

        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}