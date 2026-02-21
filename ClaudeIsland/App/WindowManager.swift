//
//  WindowManager.swift
//  ClaudeIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

// MARK: - WindowManager

/// Manages the notch window lifecycle.
/// Performs UI operations (orderOut, close, showWindow) — MainActor via default isolation.
final class WindowManager {
    // MARK: Internal

    private(set) var windowController: NotchWindowController?

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            Self.logger.warning("No screen found")
            return nil
        }

        // Skip recreation if screen hasn't meaningfully changed (same frame AND same display)
        let screenDisplayID = self.displayID(of: screen)
        if let existingController = windowController,
           let existingFrame = currentScreenFrame,
           existingFrame == screen.frame,
           currentDisplayID == screenDisplayID {
            Self.logger.debug("Screen unchanged, skipping window recreation")
            return existingController
        }

        // Only animate on initial app launch, not on screen changes
        let shouldAnimate = self.isInitialLaunch
        self.isInitialLaunch = false

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            self.windowController = nil
        }

        self.currentScreenFrame = screen.frame
        self.currentDisplayID = screenDisplayID
        self.windowController = NotchWindowController(screen: screen, animateOnLaunch: shouldAnimate)
        self.windowController?.showWindow(nil)

        return self.windowController
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Window")

    private var isInitialLaunch = true
    private var currentScreenFrame: NSRect?
    private var currentDisplayID: CGDirectDisplayID?

    /// Extract the display ID from an NSScreen
    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
