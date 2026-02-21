import AppKit
import os
@preconcurrency import Sparkle
import SwiftUI

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Lifecycle

    override init() {
        self.userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: self.userDriver,
            delegate: nil,
        )
        super.init()
        Self.shared = self

        do {
            try updater.start()
        } catch {
            Self.logger.error("Failed to start Sparkle updater: \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    static var shared: AppDelegate?

    let updater: SPUUpdater

    var windowController: NotchWindowController? {
        self.windowManager?.windowController
    }

    /// Cancel any in-flight hook installation task
    /// Called by NotchMenuView when user toggles hooks off to prevent race conditions
    func cancelHookInstallTask() {
        self.hookInstallTask?.cancel()
        self.hookInstallTask = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !self.ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        self.hookInstallTask = Task(name: "hook-install") {
            await HookInstaller.installIfNeeded()
        }
        NSApplication.shared.setActivationPolicy(.accessory)

        // Wire up agent file watcher bridge so subagent tool updates reach SessionStore
        AgentFileWatcherBridge.shared.setup()

        // Check accessibility permission on launch
        self.checkAccessibilityPermission()

        self.windowManager = WindowManager()
        _ = self.windowManager?.setupNotchWindow()

        self.screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        self.updateCheckTask = Task(name: "periodic-update-check") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard !Task.isCancelled else { break }
                guard self.updater.canCheckForUpdates else { continue }
                self.updater.checkForUpdates()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cancel any in-flight hook installation
        self.hookInstallTask?.cancel()

        // Stop socket server and clean up socket file
        HookSocketServer.shared.stop()

        // Stop interrupt watchers
        InterruptWatcherManager.shared.stopAll()

        // Stop accessibility permission monitoring
        AccessibilityPermissionManager.shared.stopPeriodicMonitoring()

        self.updateCheckTask?.cancel()
        self.screenObserver = nil
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AppDelegate")

    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTask: Task<Void, Never>?
    private var hookInstallTask: Task<Void, Never>?

    private let userDriver: NotchUserDriver

    private func handleScreenChange() {
        _ = self.windowManager?.setupNotchWindow()
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.engels74.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }

    private func checkAccessibilityPermission() {
        // Log diagnostic info for debugging TCC issues with ad-hoc signed apps
        // Use .public privacy since these are needed for debugging and don't contain user data
        let bundlePath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        Self.logger.info("App launched from: \(bundlePath, privacy: .public)")
        Self.logger.info("Bundle ID: \(bundleID, privacy: .public)")

        let manager = AccessibilityPermissionManager.shared

        if manager.shouldShowPermissionWarning {
            Self.logger.warning("Accessibility permission not granted on launch")

            // Start periodic monitoring so UI updates when permission is granted
            manager.startPeriodicMonitoring()

            // Show explanatory alert after a brief delay to explain why permission is needed
            // The alert guides users to manually add the app via "+" button in System Settings
            // (this creates a more permissive TCC entry that works with ad-hoc signed apps)
            Task(name: "accessibility-alert") {
                try? await Task.sleep(for: .seconds(1.0))
                manager.showPermissionAlert()
            }
        }
    }
}
