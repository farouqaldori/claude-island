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

/// Sound suppression modes
enum SoundSuppression: String, CaseIterable {
    case never = "Never"
    case whenFocused = "When Focused"
    case whenVisible = "When Visible"

    var description: String {
        switch self {
        case .never: return "Always play sounds"
        case .whenFocused: return "Suppress when app or session is active"
        case .whenVisible: return "Suppress when app or session is visible"
        }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let soundSuppression = "soundSuppression"
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

    // MARK: - Sound Suppression

    /// When to suppress notification sounds based on app visibility/focus
    static var soundSuppression: SoundSuppression {
        get {
            guard let rawValue = defaults.string(forKey: Keys.soundSuppression),
                  let value = SoundSuppression(rawValue: rawValue) else {
                return .whenFocused // Default
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.soundSuppression)
        }
    }
}
