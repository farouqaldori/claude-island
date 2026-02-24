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

// Unique IDs for our hotkeys
private let kApproveHotKeyID: UInt32 = 1
private let kDenyHotKeyID: UInt32 = 2
private let kCycleNextHotKeyID: UInt32 = 3
private let kCyclePrevHotKeyID: UInt32 = 4

@MainActor
class KeyboardShortcutHandler {
    static let shared = KeyboardShortcutHandler()

    private var approveHotKeyRef: EventHotKeyRef?
    private var denyHotKeyRef: EventHotKeyRef?
    private var cycleNextHotKeyRef: EventHotKeyRef?
    private var cyclePrevHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var sessionMonitor: ClaudeSessionMonitor?
    private var viewModel: NotchViewModel?

    private init() {}

    // MARK: - Public API

    func start(sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionMonitor = sessionMonitor
        self.viewModel = viewModel
        if AppSettings.shortcutsEnabled {
            registerHotKeys()
        }
    }

    func stop() {
        unregisterHotKeys()
        sessionMonitor = nil
        viewModel = nil
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

        // Install the event handler with a literal closure
        // (Swift requires a literal closure to form a C function pointer)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
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
                    case kCycleNextHotKeyID:
                        KeyboardShortcutHandler.shared.handleCycleNext()
                    case kCyclePrevHotKeyID:
                        KeyboardShortcutHandler.shared.handleCyclePrev()
                    default:
                        break
                    }
                }

                return noErr
            },
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

        // Register cycle-next hotkey (⌘⇧↓)
        var cycleNextID = EventHotKeyID(signature: fourCharCode("CISL"), id: kCycleNextHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            carbonModifiers(from: [.command, .shift]),
            cycleNextID,
            GetApplicationEventTarget(),
            0,
            &cycleNextHotKeyRef
        )

        // Register cycle-prev hotkey (⌘⇧↑)
        var cyclePrevID = EventHotKeyID(signature: fourCharCode("CISL"), id: kCyclePrevHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            carbonModifiers(from: [.command, .shift]),
            cyclePrevID,
            GetApplicationEventTarget(),
            0,
            &cyclePrevHotKeyRef
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
        if let ref = cycleNextHotKeyRef {
            UnregisterEventHotKey(ref)
            cycleNextHotKeyRef = nil
        }
        if let ref = cyclePrevHotKeyRef {
            UnregisterEventHotKey(ref)
            cyclePrevHotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Actions

    func handleApprove() {
        guard AppSettings.shortcutsEnabled, let sessionMonitor else { return }

        let targetId = viewModel?.selectedPendingSessionId
        guard let pendingSession = sessionMonitor.pendingInstances.first(where: {
            $0.phase.isWaitingForApproval && (targetId == nil || $0.sessionId == targetId)
        }) else { return }

        sessionMonitor.approvePermission(sessionId: pendingSession.sessionId)
    }

    func handleDeny() {
        guard AppSettings.shortcutsEnabled, let sessionMonitor else { return }

        let targetId = viewModel?.selectedPendingSessionId
        guard let pendingSession = sessionMonitor.pendingInstances.first(where: {
            $0.phase.isWaitingForApproval && (targetId == nil || $0.sessionId == targetId)
        }) else { return }

        sessionMonitor.denyPermission(sessionId: pendingSession.sessionId, reason: "Denied via keyboard shortcut")
    }

    func handleCycleNext() {
        guard AppSettings.shortcutsEnabled, let viewModel else { return }
        viewModel.cyclePendingSelection(direction: 1, pendingSessionIds: sortedApprovalSessionIds())
    }

    func handleCyclePrev() {
        guard AppSettings.shortcutsEnabled, let viewModel else { return }
        viewModel.cyclePendingSelection(direction: -1, pendingSessionIds: sortedApprovalSessionIds())
    }

    // MARK: - Helpers

    /// Sorted approval session IDs matching the visual order in ClaudeInstancesView
    private func sortedApprovalSessionIds() -> [String] {
        guard let sessionMonitor else { return [] }
        return sessionMonitor.pendingInstances
            .filter { $0.phase.isWaitingForApproval }
            .sorted { a, b in
                let dateA = a.lastUserMessageDate ?? a.lastActivity
                let dateB = b.lastUserMessageDate ?? b.lastActivity
                return dateA > dateB
            }
            .map { $0.sessionId }
    }

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
