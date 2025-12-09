//
//  AppDelegate.swift
//  ClaudeIsland
//
//  Dynamic Island for Claude Code instances
//

import AppKit
import Mixpanel
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?

    // Sparkle updater with custom user driver for in-notch UI
    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        // Initialize Sparkle updater with custom user driver
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        // Start the updater
        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure only one instance is running
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }
        // Initialize Mixpanel analytics
        Mixpanel.initialize(token: "49814c1436104ed108f3fc4735228496")

        // Set super properties that attach to all events
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "build_number": build,
            "macos_version": osVersion
        ])

        Mixpanel.mainInstance().track(event: "App Launched")

        // Install Claude Code hooks for accurate state detection
        HookInstaller.installIfNeeded()

        // Set as accessory app (no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)

        // Initialize managers
        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        // Check for updates every hour
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.updater.checkForUpdatesInBackground()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    // MARK: - Single Instance

    /// Ensures only one instance of Claude Island is running.
    /// Returns true if this is the only instance, false if another is already running.
    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        // If more than one instance (including this one), terminate
        if runningApps.count > 1 {
            // Activate the existing instance
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
