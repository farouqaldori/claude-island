//
//  WindowManager.swift
//  ClaudeIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.claudeisland", category: "Window")

class WindowManager {
    private(set) var windowController: NotchWindowController?
    private var isInitialLaunch = true
    private var currentScreenFrame: NSRect?

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        // Skip recreation if screen hasn't meaningfully changed
        if let existingController = windowController,
           let existingFrame = currentScreenFrame,
           existingFrame == screen.frame {
            logger.debug("Screen unchanged, skipping window recreation")
            return existingController
        }

        // Only animate on initial app launch, not on screen changes
        let shouldAnimate = isInitialLaunch
        isInitialLaunch = false

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        currentScreenFrame = screen.frame
        windowController = NotchWindowController(screen: screen, animateOnLaunch: shouldAnimate)
        windowController?.showWindow(nil)

        return windowController
    }
}
