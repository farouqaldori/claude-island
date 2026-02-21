//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation
import SwiftUI

// MARK: - TokenTrackingMode

enum TokenTrackingMode: String, CaseIterable {
    case disabled = "Disabled"
    case api = "API"

    // MARK: Internal

    var description: String {
        switch self {
        case .disabled:
            "Token tracking is off"
        case .api:
            "Fetches real quota from Claude API"
        }
    }
}

// MARK: - RingDisplay

enum RingDisplay: String, CaseIterable {
    case session = "Session"
    case weekly = "Weekly"
    case both = "Both"

    // MARK: Internal

    var showSession: Bool {
        self == .session || self == .both
    }

    var showWeekly: Bool {
        self == .weekly || self == .both
    }

    var description: String {
        switch self {
        case .session:
            "Show 5-hour session usage only"
        case .weekly:
            "Show 7-day weekly usage only"
        case .both:
            "Show both session and weekly usage"
        }
    }
}

// MARK: - SoundSuppression

/// Sound suppression modes for notification sounds
enum SoundSuppression: String, CaseIterable {
    case never = "Never"
    case whenFocused = "When Focused"
    case whenVisible = "When Visible"

    // MARK: Internal

    /// Description for UI display
    var description: String {
        switch self {
        case .never:
            "Sound always plays"
        case .whenFocused:
            "Suppresses audio when Claude Island or the terminal is active"
        case .whenVisible:
            "Suppresses audio when the terminal is visible (≥50% unobscured)"
        }
    }
}

// MARK: - NotificationSound

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

    // MARK: Internal

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

// MARK: - AppSettings

enum AppSettings {
    // MARK: Internal

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue)
            else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Sound Suppression

    /// When to suppress notification sounds
    static var soundSuppression: SoundSuppression {
        get {
            guard let rawValue = defaults.string(forKey: Keys.soundSuppression),
                  let suppression = SoundSuppression(rawValue: rawValue)
            else {
                return .whenFocused // Default to suppressing when terminal is focused
            }
            return suppression
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.soundSuppression)
        }
    }

    // MARK: - Clawd Color

    /// The color for the Clawd character
    static var clawdColor: Color {
        get {
            guard let hex = defaults.string(forKey: Keys.clawdColor) else {
                return TerminalColors.prompt
            }
            return Color(hex: hex) ?? TerminalColors.prompt
        }
        set {
            defaults.set(newValue.hexString, forKey: Keys.clawdColor)
        }
    }

    // MARK: - Clawd Always Visible

    /// Whether the Clawd character should always be visible
    static var clawdAlwaysVisible: Bool {
        get { defaults.bool(forKey: Keys.clawdAlwaysVisible) }
        set { defaults.set(newValue, forKey: Keys.clawdAlwaysVisible) }
    }

    // MARK: - Token Tracking Mode

    static var tokenTrackingMode: TokenTrackingMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.tokenTrackingMode),
                  let mode = TokenTrackingMode(rawValue: rawValue)
            else {
                return .disabled
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.tokenTrackingMode)
        }
    }

    // MARK: - Token Tracking API Settings

    static var tokenUseCLIOAuth: Bool {
        get { defaults.bool(forKey: Keys.tokenUseCLIOAuth) }
        set { defaults.set(newValue, forKey: Keys.tokenUseCLIOAuth) }
    }

    // MARK: - Token Ring Display Settings

    static var tokenShowRingsMinimized: Bool {
        get { defaults.bool(forKey: Keys.tokenShowRingsMinimized) }
        set { defaults.set(newValue, forKey: Keys.tokenShowRingsMinimized) }
    }

    static var tokenMinimizedRingDisplay: RingDisplay {
        get {
            guard let rawValue = defaults.string(forKey: Keys.tokenMinimizedRingDisplay),
                  let display = RingDisplay(rawValue: rawValue)
            else {
                return .both
            }
            return display
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.tokenMinimizedRingDisplay) }
    }

    static var tokenShowResetTime: Bool {
        get { defaults.bool(forKey: Keys.tokenShowResetTime) }
        set { defaults.set(newValue, forKey: Keys.tokenShowResetTime) }
    }

    // MARK: Private

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let soundSuppression = "soundSuppression"
        static let clawdColor = "clawdColor"
        static let clawdAlwaysVisible = "clawdAlwaysVisible"
        static let tokenTrackingMode = "tokenTrackingMode"
        static let tokenUseCLIOAuth = "tokenUseCliOAuth"
        static let tokenShowRingsMinimized = "tokenShowRingsMinimized"
        static let tokenMinimizedRingDisplay = "tokenMinimizedRingDisplay"
        static let tokenShowResetTime = "tokenShowResetTime"
    }

    private static let defaults = UserDefaults.standard
}

// MARK: - Color+Hex

extension Color {
    // MARK: Lifecycle

    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = Double((rgb & 0xFF0000) >> 16) / 255.0
        let green = Double((rgb & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        self.init(NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0))
    }

    // MARK: Internal

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3
        else {
            return "D97857"
        }

        let red = Int(components[0] * 255)
        let green = Int(components[1] * 255)
        let blue = Int(components[2] * 255)

        return String(format: "%02X%02X%02X", red, green, blue)
    }

    var hsbComponents: (hue: Double, saturation: Double, brightness: Double) {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        // Alpha parameter required by NSColor API but unused for HSB conversion
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness))
    }
}
