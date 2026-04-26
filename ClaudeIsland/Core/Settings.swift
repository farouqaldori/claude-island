//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// Display mode for the app UI
enum DisplayMode: String, CaseIterable {
    case notch = "Notch"        // Dynamic Island style at screen top
    case statusBar = "StatusBar"  // Menu bar icon with popover

    var displayName: String {
        switch self {
        case .notch: return LString.notchMode.localized
        case .statusBar: return LString.statusBarMode.localized
        }
    }

    var icon: String {
        switch self {
        case .notch: return "rectangle.topthird.inset.filled"
        case .statusBar: return "menubar.rectangle"
        }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let displayMode = "displayMode"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
            ClaudePaths.invalidateCache()
        }
    }

    // MARK: - Display Mode

    /// The UI display mode - notch (Dynamic Island) or status bar (menu bar icon)
    static var displayMode: DisplayMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.displayMode),
                  let mode = DisplayMode(rawValue: rawValue) else {
                return .notch // Default to Notch mode
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.displayMode)
        }
    }
}
