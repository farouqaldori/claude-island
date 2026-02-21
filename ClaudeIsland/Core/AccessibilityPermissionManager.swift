//
//  AccessibilityPermissionManager.swift
//  ClaudeIsland
//
//  Monitors macOS Accessibility permission status and provides UI integration
//

import AppKit
import ApplicationServices
import os

// MARK: - AccessibilityPermissionManager

/// Manages Accessibility permission state for the app.
/// Required for global mouse event monitoring and CGEvent posting.
@Observable
final class AccessibilityPermissionManager {
    // MARK: Lifecycle

    private init() {
        self.checkPermission()
        // If permission is already granted (returning user), start event monitors immediately
        EventMonitors.shared.startMonitorsIfPermitted()
    }

    // MARK: Internal

    static let shared = AccessibilityPermissionManager()

    /// Current accessibility permission state (actual AXIsProcessTrusted value)
    private(set) var isAccessibilityEnabled = false

    /// Whether to show the permission warning in UI
    /// Debug builds have different code signatures than release builds, so TCC permissions
    /// granted to the installed app don't apply. Suppress the misleading warning during development.
    var shouldShowPermissionWarning: Bool {
        #if DEBUG
            return false
        #else
            return !self.isAccessibilityEnabled
        #endif
    }

    /// Check the current permission state
    func checkPermission() {
        let previousState = self.isAccessibilityEnabled
        let newState = AXIsProcessTrusted()
        self.isAccessibilityEnabled = newState

        let bundlePath = Bundle.main.bundlePath
        Self.logger
            .info(
                "Accessibility check: AXIsProcessTrusted() = \(newState), isDebugBuild = \(self.isDebugBuild), bundle: \(bundlePath, privacy: .private)",
            )

        if previousState != newState {
            Self.logger.warning("Accessibility permission CHANGED: \(previousState) -> \(newState)")

            // Permission just granted — start deferred event monitors
            if newState {
                EventMonitors.shared.startMonitorsIfPermitted()
            }
        }
    }

    /// Start periodic monitoring until permission is granted
    /// Uses adaptive polling: 0.5s for first 30s, then 2s thereafter
    func startPeriodicMonitoring() {
        // Don't start if already monitoring
        guard self.pollingTask == nil else { return }

        // If already enabled, no need to monitor
        if self.isAccessibilityEnabled { return }

        Self.logger.info("Starting periodic accessibility permission monitoring (fast mode)")

        // Record start time for adaptive polling
        self.monitoringStartTime = Date()
        self.currentPollingInterval = self.fastPollingInterval

        self.pollingTask = Task(name: "accessibility-poll") {
            while !Task.isCancelled {
                self.checkPermission()

                if self.isAccessibilityEnabled {
                    Self.logger.info("Accessibility permission granted, stopping monitoring")
                    break
                }

                self.adjustPollingIntervalIfNeeded()
                try? await Task.sleep(for: .seconds(self.currentPollingInterval))
            }

            // Clean up stale state so startPeriodicMonitoring() can restart if needed
            self.pollingTask = nil
            self.monitoringStartTime = nil
        }
    }

    /// Stop periodic monitoring
    func stopPeriodicMonitoring() {
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.monitoringStartTime = nil
    }

    /// Open System Preferences directly to Accessibility settings
    func openAccessibilitySettings() {
        Self.logger.info("Opening Accessibility settings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Start monitoring after opening settings
        self.startPeriodicMonitoring()
    }

    /// Show an alert explaining why accessibility permission is needed
    /// Returns true if user clicked "Open Settings", false if they clicked "Later"
    @discardableResult
    func showPermissionAlert() -> Bool {
        // Log diagnostic info for debugging TCC issues (use .public privacy for diagnostic visibility)
        let bundlePath = Bundle.main.bundlePath
        Self.logger.info("Showing permission alert. Bundle path: \(bundlePath, privacy: .public)")

        // CRITICAL: Before showing modal alert, hide the notch window
        // The notch window sits at a high window level and visually blocks the alert
        let notchWindow = NSApp.windows.first { $0 is NotchPanel }
        let wasVisible = notchWindow?.isVisible ?? false
        notchWindow?.orderOut(nil)

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Claude Island needs Accessibility permission to:

        \u{2022} Monitor mouse position to show/hide the notch
        \u{2022} Pass clicks through to apps behind the notch

        To grant permission:
        1. Click "Open Settings" below
        2. Click the "+" button at the bottom of the list
        3. Navigate to and select the Claude Island app bundle
        4. Enable the checkbox next to Claude Island

        Important: If Claude Island is already in the list but not working, \
        remove it first using the "-" button, then add it again using "+".
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        // Restore notch window visibility after alert dismissal
        if wasVisible {
            notchWindow?.orderFront(nil)
        }

        if response == .alertFirstButtonReturn {
            self.openAccessibilitySettings()
            return true
        }

        return false
    }

    /// Handle app becoming active - check permission and restart fast polling if needed
    func handleAppActivation() {
        let previousState = self.isAccessibilityEnabled
        self.checkPermission()

        // If still not enabled, start or restart periodic monitoring
        // This ensures we poll for permission changes even if monitoring wasn't running
        if !self.isAccessibilityEnabled {
            Self.logger.info("App activated without accessibility - starting/restarting monitoring")
            self.stopPeriodicMonitoring()
            self.startPeriodicMonitoring()
        }

        if previousState != self.isAccessibilityEnabled {
            Self.logger.warning("Permission detected on activation: \(previousState) -> \(self.isAccessibilityEnabled)")

            // Permission just granted on activation — start deferred event monitors
            if self.isAccessibilityEnabled {
                EventMonitors.shared.startMonitorsIfPermitted()
            }
        }
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AccessibilityPermission")

    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    /// Time when monitoring started (for adaptive polling)
    @ObservationIgnored private var monitoringStartTime: Date?

    /// Duration of fast polling after monitoring starts (30 seconds)
    private let fastPollingDuration: TimeInterval = 30.0

    /// Fast polling interval during initial monitoring
    private let fastPollingInterval: TimeInterval = 0.5

    /// Slow polling interval after initial period
    private let slowPollingInterval: TimeInterval = 2.0

    /// Current polling interval (tracks which mode we're in)
    @ObservationIgnored private var currentPollingInterval: TimeInterval = 0.5

    /// Detect if running from Xcode's DerivedData (debug build)
    /// Debug builds have different code signatures than release builds,
    /// so TCC permissions granted to the installed app don't apply
    private var isDebugBuild: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.contains("DerivedData") || bundlePath.contains("Build/Products/Debug")
    }

    /// Adjust polling interval from fast to slow after the initial period
    private func adjustPollingIntervalIfNeeded() {
        guard let startTime = self.monitoringStartTime,
              self.currentPollingInterval == self.fastPollingInterval
        else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= self.fastPollingDuration {
            Self.logger.info("Switching to slow polling mode after \(Int(elapsed))s")
            self.currentPollingInterval = self.slowPollingInterval
        }
    }
}
