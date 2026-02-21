//
//  NotchUserDriver.swift
//  ClaudeIsland
//
//  Custom Sparkle user driver for in-notch update UI
//

import Foundation
import Observation
@preconcurrency import Sparkle

// MARK: - UpdateState

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case found(version: String, releaseNotes: String?)
    case downloading(progress: Double) // 0.0 to 1.0
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    // MARK: Internal

    var isActive: Bool {
        switch self {
        case .idle,
             .upToDate,
             .error:
            false
        default:
            true
        }
    }
}

// MARK: - UpdateManager

/// Observable update manager that bridges Sparkle to SwiftUI
@Observable
final class UpdateManager {
    // MARK: Internal

    static let shared = UpdateManager()

    var state: UpdateState = .idle
    var hasUnseenUpdate = false

    // MARK: - Public API

    func checkForUpdates() {
        self.state = .checking
        if let updater = AppDelegate.shared?.updater {
            updater.checkForUpdates()
        } else {
            self.state = .error(message: "Updater not initialized")
        }
    }

    func downloadAndInstall() {
        self.installHandler?(.install)
    }

    func installAndRelaunch() {
        self.installHandler?(.install)
    }

    func skipUpdate() {
        self.installHandler?(.skip)
        self.state = .idle
    }

    func dismissUpdate() {
        self.installHandler?(.dismiss)
        self.state = .idle
    }

    func cancelDownload() {
        self.cancellationHandler?()
        self.state = .idle
    }

    // MARK: - Internal state updates (called by NotchUserDriver)

    func updateFound(version: String, releaseNotes: String?, installHandler: @escaping (SPUUserUpdateChoice) -> Void) {
        self.currentVersion = version
        self.installHandler = installHandler
        self.state = .found(version: version, releaseNotes: releaseNotes)
        // Only show the dot if user hasn't seen it this session
        if !self.hasSeenUpdateThisSession {
            self.hasUnseenUpdate = true
        }
    }

    func markUpdateSeen() {
        self.hasUnseenUpdate = false
        self.hasSeenUpdateThisSession = true
    }

    func downloadStarted(cancellation: @escaping () -> Void) {
        self.cancellationHandler = cancellation
        self.downloadedBytes = 0
        self.expectedBytes = 0
        self.state = .downloading(progress: 0)
    }

    func downloadExpectedLength(_ length: UInt64) {
        self.expectedBytes = Int64(length)
    }

    func downloadReceivedData(_ length: UInt64) {
        self.downloadedBytes += Int64(length)
        let progress = self.expectedBytes > 0 ? Double(self.downloadedBytes) / Double(self.expectedBytes) : 0
        self.state = .downloading(progress: min(progress, 1.0))
    }

    func extractionStarted() {
        self.state = .extracting(progress: 0)
    }

    func extractionProgress(_ progress: Double) {
        self.state = .extracting(progress: progress)
    }

    func readyToInstall(installHandler: @escaping (SPUUserUpdateChoice) -> Void) {
        self.installHandler = installHandler
        self.state = .readyToInstall(version: self.currentVersion)
    }

    func installing() {
        self.state = .installing
    }

    func installed(relaunched: Bool) {
        self.state = .idle
    }

    func noUpdateFound() {
        self.state = .upToDate
        // Cancel any previous reset task
        self.upToDateResetTask?.cancel()
        // Reset to idle after a few seconds
        self.upToDateResetTask = Task(name: "update-state-reset") {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if case .upToDate = self.state {
                self.state = .idle
            }
        }
    }

    func updateError(_ message: String) {
        self.state = .error(message: message)
    }

    func dismiss() {
        // Don't dismiss if we're showing "up to date" - let it display
        if case .upToDate = self.state {
            return
        }
        self.upToDateResetTask?.cancel()
        self.upToDateResetTask = nil
        self.state = .idle
        self.installHandler = nil
        self.cancellationHandler = nil
    }

    // MARK: Private

    private var hasSeenUpdateThisSession = false

    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    private var currentVersion = ""

    // Callbacks from Sparkle
    private var installHandler: ((SPUUserUpdateChoice) -> Void)?
    private var cancellationHandler: (() -> Void)?

    /// Task for delayed state reset after "up to date" message
    private var upToDateResetTask: Task<Void, Never>?
}

// MARK: - NotchUserDriver

/// Custom Sparkle user driver that routes all UI to NotchUpdateManager
class NotchUserDriver: NSObject, SPUUserDriver {
    var canCheckForUpdates: Bool {
        true
    }

    // MARK: - Update Found

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Auto-approve update checks
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Task(name: "update-checking") { @MainActor in
            UpdateManager.shared.state = .checking
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let releaseNotes = appcastItem.itemDescription

        Task(name: "update-found") { @MainActor in
            UpdateManager.shared.updateFound(version: version, releaseNotes: releaseNotes, installHandler: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes downloaded - we already have them from appcastItem
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Ignore release notes failures
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task(name: "update-not-found") { @MainActor in
            UpdateManager.shared.noUpdateFound()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task(name: "update-error") { @MainActor in
            UpdateManager.shared.updateError(error.localizedDescription)
        }
        acknowledgement()
    }

    // MARK: - Download Progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        Task(name: "download-started") { @MainActor in
            UpdateManager.shared.downloadStarted(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        Task(name: "download-length") { @MainActor in
            UpdateManager.shared.downloadExpectedLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        Task(name: "download-progress") { @MainActor in
            UpdateManager.shared.downloadReceivedData(length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        Task(name: "extraction-started") { @MainActor in
            UpdateManager.shared.extractionStarted()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        Task(name: "extraction-progress") { @MainActor in
            UpdateManager.shared.extractionProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Task(name: "ready-to-install") { @MainActor in
            UpdateManager.shared.readyToInstall(installHandler: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        Task(name: "update-installing") { @MainActor in
            UpdateManager.shared.installing()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Task(name: "update-installed") { @MainActor in
            UpdateManager.shared.installed(relaunched: relaunched)
        }
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        Task(name: "update-dismissed") { @MainActor in
            UpdateManager.shared.dismiss()
        }
    }

    // MARK: - Resume/Focus

    func showUpdateInFocus() {
        // Could expand notch here if desired
    }

    func showResumableUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Resumable update - treat same as regular update found
        self.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showInformationalUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Informational only - dismiss for now
        reply(.dismiss)
    }
}
