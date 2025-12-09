//
//  NotchUserDriver.swift
//  ClaudeIsland
//
//  Custom Sparkle user driver for in-notch update UI
//

import Combine
import Foundation
import Sparkle

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case found(version: String, releaseNotes: String?)
    case downloading(progress: Double)  // 0.0 to 1.0
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    var isActive: Bool {
        switch self {
        case .idle, .error:
            return false
        default:
            return true
        }
    }
}

/// Observable update manager that bridges Sparkle to SwiftUI
@MainActor
class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle

    private var downloadedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    private var currentVersion: String = ""

    // Callbacks from Sparkle
    private var installHandler: ((SPUUserUpdateChoice) -> Void)?
    private var cancellationHandler: (() -> Void)?

    override init() {
        super.init()
    }

    // MARK: - Public API

    func checkForUpdates() {
        state = .checking
        AppDelegate.shared?.updater.checkForUpdatesInBackground()
    }

    func downloadAndInstall() {
        installHandler?(.install)
    }

    func installAndRelaunch() {
        installHandler?(.install)
    }

    func skipUpdate() {
        installHandler?(.skip)
        state = .idle
    }

    func dismissUpdate() {
        installHandler?(.dismiss)
        state = .idle
    }

    func cancelDownload() {
        cancellationHandler?()
        state = .idle
    }

    // MARK: - Internal state updates (called by NotchUserDriver)

    func updateFound(version: String, releaseNotes: String?, installHandler: @escaping (SPUUserUpdateChoice) -> Void) {
        self.currentVersion = version
        self.installHandler = installHandler
        self.state = .found(version: version, releaseNotes: releaseNotes)
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
        let progress = expectedBytes > 0 ? Double(downloadedBytes) / Double(expectedBytes) : 0
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
        self.state = .readyToInstall(version: currentVersion)
    }

    func installing() {
        self.state = .installing
    }

    func installed(relaunched: Bool) {
        self.state = .idle
    }

    func noUpdateFound() {
        self.state = .idle
    }

    func updateError(_ message: String) {
        self.state = .error(message: message)
    }

    func dismiss() {
        self.state = .idle
        self.installHandler = nil
        self.cancellationHandler = nil
    }
}

/// Custom Sparkle user driver that routes all UI to NotchUpdateManager
class NotchUserDriver: NSObject, SPUUserDriver {

    var canCheckForUpdates: Bool { true }

    // MARK: - Update Found

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Auto-approve update checks
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // User started a check - just let it proceed
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let releaseNotes = appcastItem.itemDescription

        Task { @MainActor in
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
        Task { @MainActor in
            UpdateManager.shared.noUpdateFound()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.updateError(error.localizedDescription)
        }
        acknowledgement()
    }

    // MARK: - Download Progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.downloadStarted(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        Task { @MainActor in
            UpdateManager.shared.downloadExpectedLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        Task { @MainActor in
            UpdateManager.shared.downloadReceivedData(length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        Task { @MainActor in
            UpdateManager.shared.extractionStarted()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        Task { @MainActor in
            UpdateManager.shared.extractionProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Task { @MainActor in
            UpdateManager.shared.readyToInstall(installHandler: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.installing()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Task { @MainActor in
            UpdateManager.shared.installed(relaunched: relaunched)
        }
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        Task { @MainActor in
            UpdateManager.shared.dismiss()
        }
    }

    // MARK: - Resume/Focus

    func showUpdateInFocus() {
        // Could expand notch here if desired
    }

    func showResumableUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Resumable update - treat same as regular update found
        showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showInformationalUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Informational only - dismiss for now
        reply(.dismiss)
    }
}
