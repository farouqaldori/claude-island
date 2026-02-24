//
//  KeyboardShortcutHandler.swift
//  ClaudeIsland
//
//  Global keyboard shortcuts for approve/deny permission requests
//

import AppKit
import Carbon.HIToolbox

@MainActor
class KeyboardShortcutHandler {
    static let shared = KeyboardShortcutHandler()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var sessionMonitor: ClaudeSessionMonitor?

    private init() {}

    // MARK: - Public API

    func start(sessionMonitor: ClaudeSessionMonitor) {
        self.sessionMonitor = sessionMonitor
        startMonitoring()
    }

    func stop() {
        stopMonitoring()
        sessionMonitor = nil
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        stopMonitoring()

        // Global monitor: fires when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        // Local monitor: fires when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Key Handling

    private func handleKeyDown(_ event: NSEvent) {
        guard AppSettings.shortcutsEnabled else { return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        let approveShortcut = AppSettings.approveShortcut
        let denyShortcut = AppSettings.denyShortcut

        if modifiers == approveShortcut.modifiers && keyCode == approveShortcut.keyCode {
            handleApprove()
        } else if modifiers == denyShortcut.modifiers && keyCode == denyShortcut.keyCode {
            handleDeny()
        }
    }

    private func handleApprove() {
        guard let sessionMonitor else { return }

        // Find the most recent session waiting for approval
        guard let pendingSession = sessionMonitor.pendingInstances.first(where: { $0.phase.isWaitingForApproval }) else {
            return
        }

        sessionMonitor.approvePermission(sessionId: pendingSession.sessionId)
        ShortcutFeedback.flash(.approve)
    }

    private func handleDeny() {
        guard let sessionMonitor else { return }

        guard let pendingSession = sessionMonitor.pendingInstances.first(where: { $0.phase.isWaitingForApproval }) else {
            return
        }

        sessionMonitor.denyPermission(sessionId: pendingSession.sessionId, reason: "Denied via keyboard shortcut")
        ShortcutFeedback.flash(.deny)
    }
}
