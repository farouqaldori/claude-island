//
//  Ext+NSScreen.swift
//  ClaudeIsland
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    /// The menu bar height on this screen
    var menuBarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// Returns the size of the notch on this screen (pixel-perfect using macOS APIs).
    /// On non-notch displays, returns a pill-sized rect matching the menu bar height.
    var notchSize: CGSize {
        guard hasPhysicalNotch else {
            // Pill dimensions for non-notch displays — compact to fit in menu bar
            return CGSize(width: 180, height: 22)
        }

        let notchHeight = safeAreaInsets.top
        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0

        guard leftPadding > 0, rightPadding > 0 else {
            // Fallback if auxiliary areas unavailable
            return CGSize(width: 180, height: notchHeight)
        }

        // +4 to match boring.notch's calculation for proper alignment
        let notchWidth = fullWidth - leftPadding - rightPadding + 4
        return CGSize(width: notchWidth, height: notchHeight)
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }

    /// Whether this screen has a physical notch (camera housing).
    /// Only the built-in display can have a physical notch.
    var hasPhysicalNotch: Bool {
        isBuiltinDisplay && safeAreaInsets.top > 0
    }
}
