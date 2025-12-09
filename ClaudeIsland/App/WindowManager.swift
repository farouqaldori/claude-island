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

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // Find the screen with the notch (built-in display), or fallback to main
        let screen = NSScreen.builtin ?? NSScreen.main

        guard let screen = screen else {
            logger.warning("No screen found")
            return nil
        }

        // Close existing window
        windowController?.window?.close()

        // Create new window controller
        windowController = NotchWindowController(screen: screen)
        windowController?.showWindow(nil)

        return windowController
    }
}
