//
//  KeyboardShortcut.swift
//  ClaudeIsland
//
//  Model for a keyboard shortcut (modifier flags + key code)
//

import AppKit
import Carbon.HIToolbox

struct KeyCombo: Equatable, Codable {
    let keyCode: UInt16
    let modifierFlags: UInt  // Raw value of NSEvent.ModifierFlags

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    /// Human-readable display string (e.g. "⌘⇧Y")
    var displayString: String {
        var parts: [String] = []
        let mods = modifiers

        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }

        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    // MARK: - Defaults

    /// Default: ⌘⇧Y
    static let defaultApprove = KeyCombo(
        keyCode: UInt16(kVK_ANSI_Y),
        modifiers: [.command, .shift]
    )

    /// Default: ⌘⇧N
    static let defaultDeny = KeyCombo(
        keyCode: UInt16(kVK_ANSI_N),
        modifiers: [.command, .shift]
    )
}

// MARK: - Key Code to String

private func keyCodeToString(_ keyCode: UInt16) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Escape: return "⎋"
    case kVK_Delete: return "⌫"
    case kVK_Tab: return "⇥"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return "?"
    }
}
