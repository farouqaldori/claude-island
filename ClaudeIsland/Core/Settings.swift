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

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let approveShortcut = "approveShortcut"
        static let denyShortcut = "denyShortcut"
        static let shortcutsEnabled = "shortcutsEnabled"
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

    // MARK: - Keyboard Shortcuts

    /// Whether global keyboard shortcuts are enabled
    static var shortcutsEnabled: Bool {
        get {
            // Default to true if never set
            if defaults.object(forKey: Keys.shortcutsEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.shortcutsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.shortcutsEnabled)
        }
    }

    /// Keyboard shortcut for approving permissions (default: ⌘⇧Y)
    static var approveShortcut: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Keys.approveShortcut),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
                return .defaultApprove
            }
            return combo
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.approveShortcut)
            }
        }
    }

    /// Keyboard shortcut for denying permissions (default: ⌘⇧N)
    static var denyShortcut: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Keys.denyShortcut),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
                return .defaultDeny
            }
            return combo
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.denyShortcut)
            }
        }
    }
}
