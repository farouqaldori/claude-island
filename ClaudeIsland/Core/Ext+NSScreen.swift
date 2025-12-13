//
//  Ext+NSScreen.swift
//  ClaudeIsland
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

enum NotchStyle: String, Codable, CaseIterable {
    case `default`
    case neat

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .neat: return "Neat"
        }
    }

    var sublabel: String {
        switch self {
        case .default: return "Physical Notch"
        case .neat: return "Menu Bar Height"
        }
    }
}

extension NSScreen {
    static let menuBarHeight: CGFloat = 25

    /// Returns the size of the notch on this screen (pixel-perfect using macOS APIs)
    var notchSize: CGSize {
        notchSize(for: .default)
    }

    /// Returns the size of the notch for a given style
    func notchSize(for style: NotchStyle) -> CGSize {
        switch style {
        case .neat:
            let fullWidth = frame.width
            let leftPadding = auxiliaryTopLeftArea?.width ?? 0
            let rightPadding = auxiliaryTopRightArea?.width ?? 0

            if leftPadding > 0, rightPadding > 0 {
                let notchWidth = fullWidth - leftPadding - rightPadding + 4
                return CGSize(width: notchWidth, height: NSScreen.menuBarHeight)
            } else {
                return CGSize(width: 180, height: NSScreen.menuBarHeight)
            }

        case .default:
            guard safeAreaInsets.top > 0 else {
                return CGSize(width: 224, height: 38)
            }

            let notchHeight = safeAreaInsets.top
            let fullWidth = frame.width
            let leftPadding = auxiliaryTopLeftArea?.width ?? 0
            let rightPadding = auxiliaryTopRightArea?.width ?? 0

            guard leftPadding > 0, rightPadding > 0 else {
                return CGSize(width: 180, height: notchHeight)
            }

            let notchWidth = fullWidth - leftPadding - rightPadding + 4
            return CGSize(width: notchWidth, height: notchHeight)
        }
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

    /// Whether this screen has a physical notch (camera housing)
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }
}
