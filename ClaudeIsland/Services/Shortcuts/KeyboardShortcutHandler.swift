//
//  KeyboardShortcutHandler.swift
//  ClaudeIsland
//
//  Global keyboard shortcuts for approve/deny permission requests.
//  Uses Carbon RegisterEventHotKey for true system-wide hotkeys
//  that work regardless of which app is focused.
//

import AppKit
import Carbon.HIToolbox

// Unique IDs for our two hotkeys
private let kApproveHotKeyID: UInt32 = 1
private let kDenyHotKeyID: UInt32 = 2

// Global C callback — Carbon hotkey events land here
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    Task { @MainActor in
        switch hotKeyID.id {
        case kApproveHotKeyID:
            KeyboardShortcutHandler.shared.handleApprove()
        case kDenyHotKeyID:
            KeyboardShortcutHandler.shared.handleDeny()
        default:
            break
        }
    }

    return noErr
}

@MainActor
class KeyboardShortcutHandler {
    static let shared = KeyboardShortcutHandler()

    private var approveHotKeyRef: EventHotKeyRef?
    private var denyHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var sessionMonitor: ClaudeSessionMonitor?

    private init() {}

    // MARK: - Public API

    func start(sessionMonitor: ClaudeSessionMonitor) {
        self.sessionMonitor = sessionMonitor
        if AppSettings.shortcutsEnabled {
            registerHotKeys()
        }
    }

    func stop() {
        unregisterHotKeys()
        sessionMonitor = nil
    }

    /// Re-register hotkeys after settings change
    func reloadShortcuts() {
        unregisterHotKeys()
        if AppSettings.shortcutsEnabled {
            registerHotKeys()
        }
    }

    // MARK: - Carbon Hotkey Registration

    private func registerHotKeys() {
        unregisterHotKeys()

        // Install the event handler (once)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        // Register approve hotkey
        let approveCombo = AppSettings.approveShortcut
        var approveID = EventHotKeyID(signature: fourCharCode("CISL"), id: kApproveHotKeyID)
        RegisterEventHotKey(
            UInt32(approveCombo.keyCode),
            carbonModifiers(from: approveCombo.modifiers),
            approveID,
            GetApplicationEventTarget(),
            0,
            &approveHotKeyRef
        )

        // Register deny hotkey
        let denyCombo = AppSettings.denyShortcut
        var denyID = EventHotKeyID(signature: fourCharCode("CISL"), id: kDenyHotKeyID)
        RegisterEventHotKey(
            UInt32(denyCombo.keyCode),
            carbonModifiers(from: denyCombo.modifiers),
            denyID,
            GetApplicationEventTarget(),
            0,
            &denyHotKeyRef
        )
    }

    private func unregisterHotKeys() {
        if let ref = approveHotKeyRef {
            UnregisterEventHotKey(ref)
            approveHotKeyRef = nil
        }
        if let ref = denyHotKeyRef {
            UnregisterEventHotKey(ref)
            denyHotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Actions

    func handleApprove() {
        guard AppSettings.shortcutsEnabled, let sessionMonitor else { return }

        guard let pendingSession = sessionMonitor.pendingInstances.first(where: { $0.phase.isWaitingForApproval }) else {
            return
        }

        sessionMonitor.approvePermission(sessionId: pendingSession.sessionId)
        ShortcutFeedback.flash(.approve)
    }

    func handleDeny() {
        guard AppSettings.shortcutsEnabled, let sessionMonitor else { return }

        guard let pendingSession = sessionMonitor.pendingInstances.first(where: { $0.phase.isWaitingForApproval }) else {
            return
        }

        sessionMonitor.denyPermission(sessionId: pendingSession.sessionId, reason: "Denied via keyboard shortcut")
        ShortcutFeedback.flash(.deny)
    }

    // MARK: - Helpers

    /// Convert NSEvent.ModifierFlags to Carbon modifier mask
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// Convert a 4-character string to OSType (FourCharCode)
private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for char in string.utf8.prefix(4) {
        result = result << 8 + OSType(char)
    }
    return result
}
