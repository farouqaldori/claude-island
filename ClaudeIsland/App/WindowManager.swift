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
    private var isHidden = false

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

    /// Hide the notch window (for status bar mode)
    func hideNotchWindow() {
        guard let controller = windowController else { return }
        controller.window?.orderOut(nil)
        isHidden = true
        logger.debug("Notch window hidden")
    }

    /// Show the notch window (switching back to notch mode)
    func showNotchWindow() {
        guard let controller = windowController else {
            // Recreate if needed
            _ = setupNotchWindow()
            return
        }
        controller.window?.makeKeyAndOrderFront(nil)
        isHidden = false
        logger.debug("Notch window shown")
    }

    /// Check if the notch window is currently hidden
    func isNotchHidden() -> Bool {
        return isHidden
    }
}
