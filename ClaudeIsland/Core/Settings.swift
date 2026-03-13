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
        static let readAloudEnabled = "readAloudEnabled"
        static let selectedVoiceId = "selectedVoiceId"
        static let useAnthropicSTT = "useAnthropicSTT"
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

    // MARK: - Read Aloud (TTS)

    /// Whether to read assistant responses aloud when Claude finishes
    static var readAloudEnabled: Bool {
        get { defaults.bool(forKey: Keys.readAloudEnabled) }
        set { defaults.set(newValue, forKey: Keys.readAloudEnabled) }
    }

    /// The selected voice identifier for TTS
    static var selectedVoiceId: String? {
        get { defaults.string(forKey: Keys.selectedVoiceId) }
        set { defaults.set(newValue, forKey: Keys.selectedVoiceId) }
    }

    /// Use Anthropic's cloud STT instead of Apple's on-device speech recognition
    static var useAnthropicSTT: Bool {
        get { defaults.bool(forKey: Keys.useAnthropicSTT) }
        set { defaults.set(newValue, forKey: Keys.useAnthropicSTT) }
    }
}
