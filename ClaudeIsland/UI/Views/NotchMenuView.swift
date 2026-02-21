// swiftlint:disable file_length
//
//  NotchMenuView.swift
//  ClaudeIsland
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import os
import ServiceManagement
@preconcurrency import Sparkle
import SwiftUI

// MARK: - NotchMenuView

struct NotchMenuView: View {
    // MARK: Lifecycle

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Internal

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                ) {
                    self.viewModel.toggleMenu()
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // Appearance settings
                ScreenPickerRow(screenSelector: self.screenSelector)
                SoundPickerRow(soundSelector: self.soundSelector)
                SuppressionPickerRow(suppressionSelector: self.suppressionSelector)
                ClawdPickerRow(clawdSelector: self.clawdSelector)

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // Token tracking
                TokenTrackingRow(tokenTrackingManager: self.tokenTrackingManager)

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // System settings
                MenuToggleRow(
                    icon: "power",
                    label: "Launch at Login",
                    isOn: self.launchAtLogin,
                ) {
                    do {
                        if self.launchAtLogin {
                            try SMAppService.mainApp.unregister()
                            self.launchAtLogin = false
                        } else {
                            try SMAppService.mainApp.register()
                            self.launchAtLogin = true
                        }
                    } catch {
                        Self.logger.error("Failed to toggle launch at login: \(error.localizedDescription)")
                    }
                }

                MenuToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Hooks",
                    isOn: self.hooksInstalled,
                ) {
                    // Cancel any in-flight installation tasks first (both local and AppDelegate's)
                    // This prevents race conditions where an app-launch install could re-write settings.json
                    // after uninstall completes
                    self.hookInstallTask?.cancel()
                    self.hookInstallTask = nil
                    AppDelegate.shared?.cancelHookInstallTask()

                    if self.hooksInstalled {
                        HookInstaller.uninstall()
                        self.hooksInstalled = false
                    } else {
                        self.hookInstallTask = Task(name: "install-hooks") { @MainActor in
                            await HookInstaller.installIfNeeded()
                            // Only update state if task wasn't cancelled
                            if !Task.isCancelled {
                                self.hooksInstalled = HookInstaller.isInstalled()
                            }
                        }
                    }
                }

                AccessibilityRow(accessibilityManager: self.accessibilityManager)

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                // About
                UpdateRow(updateManager: self.updateManager)

                MenuRow(
                    icon: "star",
                    label: "Star on GitHub",
                ) {
                    if let url = URL(string: "https://github.com/engels74/claude-island") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "xmark.circle",
                    label: "Quit",
                    isDestructive: true,
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            self.refreshStates()
        }
        .onChange(of: self.viewModel.contentType) { _, newValue in
            if newValue == .menu {
                self.refreshStates()
            }
        }
        .onDisappear {
            // Cancel any in-flight hook installation when view disappears
            self.hookInstallTask?.cancel()
        }
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "NotchMenuView")

    @State private var hooksInstalled = false
    @State private var launchAtLogin = false
    @State private var hookInstallTask: Task<Void, Never>?

    private var updateManager = UpdateManager.shared

    /// Singletons are @Observable, so SwiftUI automatically tracks property access
    private var screenSelector = ScreenSelector.shared
    private var soundSelector = SoundSelector.shared
    private var suppressionSelector = SuppressionSelector.shared
    private var clawdSelector = ClawdSelector.shared
    private var accessibilityManager = AccessibilityPermissionManager.shared
    private var tokenTrackingManager = TokenTrackingManager.shared

    private func refreshStates() {
        self.hooksInstalled = HookInstaller.isInstalled()
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.screenSelector.refreshScreens()
    }
}

// MARK: - UpdateRow

struct UpdateRow: View {
    // MARK: Internal

    var updateManager: UpdateManager

    var body: some View {
        Button {
            self.handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = self.updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(self.isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: self.isSpinning)
                            .onAppear { self.isSpinning = true }
                    } else {
                        Image(systemName: self.icon)
                            .font(.system(size: 12))
                            .foregroundColor(self.iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(self.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(self.labelColor)

                Spacer()

                // Right side: progress or status
                self.rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.isHovered && self.isInteractive ? Color.white.opacity(0.08) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .disabled(!self.isInteractive)
        .onHover { self.isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: self.updateManager.state)
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private var icon: String {
        switch self.updateManager.state {
        case .idle:
            "arrow.down.circle"
        case .checking:
            "arrow.down.circle"
        case .upToDate:
            "checkmark.circle.fill"
        case .found:
            "arrow.down.circle.fill"
        case .downloading:
            "arrow.down.circle"
        case .extracting:
            "doc.zipper"
        case .readyToInstall:
            "checkmark.circle.fill"
        case .installing:
            "gear"
        case .error:
            "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch self.updateManager.state {
        case .idle:
            .white.opacity(self.isHovered ? 1.0 : 0.7)
        case .checking:
            .white.opacity(0.7)
        case .upToDate:
            TerminalColors.green
        case .found,
             .readyToInstall:
            TerminalColors.green
        case .downloading:
            TerminalColors.blue
        case .extracting:
            TerminalColors.amber
        case .installing:
            TerminalColors.blue
        case .error:
            Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch self.updateManager.state {
        case .idle:
            "Check for Updates"
        case .checking:
            "Checking..."
        case .upToDate:
            "Check for Updates"
        case .found:
            "Download Update"
        case .downloading:
            "Downloading..."
        case .extracting:
            "Extracting..."
        case .readyToInstall:
            "Install & Relaunch"
        case .installing:
            "Installing..."
        case .error:
            "Update failed"
        }
    }

    private var labelColor: Color {
        switch self.updateManager.state {
        case .idle,
             .upToDate:
            .white.opacity(self.isHovered ? 1.0 : 0.7)
        case .checking,
             .downloading,
             .extracting,
             .installing:
            .white.opacity(0.9)
        case .found,
             .readyToInstall:
            TerminalColors.green
        case .error:
            Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch self.updateManager.state {
        case .idle,
             .upToDate,
             .found,
             .readyToInstall,
             .error:
            true
        case .checking,
             .downloading,
             .extracting,
             .installing:
            false
        }
    }

    // MARK: - Right Content

    @ViewBuilder private var rightContent: some View {
        switch self.updateManager.state {
        case .idle:
            Text(self.appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking,
             .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case let .found(version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case let .extracting(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case let .readyToInstall(version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func handleTap() {
        switch self.updateManager.state {
        case .idle,
             .upToDate,
             .error:
            self.updateManager.checkForUpdates()
        case .found:
            self.updateManager.downloadAndInstall()
        case .readyToInstall:
            self.updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - AccessibilityRow

struct AccessibilityRow: View {
    // MARK: Internal

    /// AccessibilityPermissionManager is @Observable, so SwiftUI automatically tracks property access
    var accessibilityManager: AccessibilityPermissionManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(self.textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(self.textColor)

            Spacer()

            if !self.accessibilityManager.shouldShowPermissionWarning {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: self.handleEnableAction) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(TerminalColors.amber),
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
        )
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false

    private var textColor: Color {
        if self.accessibilityManager.shouldShowPermissionWarning {
            return TerminalColors.amber.opacity(self.isHovered ? 1.0 : 0.8)
        }
        return .white.opacity(self.isHovered ? 1.0 : 0.7)
    }

    private func handleEnableAction() {
        self.accessibilityManager.openAccessibilitySettings()
    }
}

// MARK: - MenuRow

struct MenuRow: View {
    // MARK: Internal

    let icon: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 10) {
                Image(systemName: self.icon)
                    .font(.system(size: 12))
                    .foregroundColor(self.textColor)
                    .frame(width: 16)

                Text(self.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(self.textColor)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false

    private var textColor: Color {
        if self.isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(self.isHovered ? 1.0 : 0.7)
    }
}

// MARK: - MenuToggleRow

struct MenuToggleRow: View {
    // MARK: Internal

    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 10) {
                Image(systemName: self.icon)
                    .font(.system(size: 12))
                    .foregroundColor(self.textColor)
                    .frame(width: 16)

                Text(self.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(self.textColor)

                Spacer()

                Circle()
                    .fill(self.isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(self.isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false

    private var textColor: Color {
        .white.opacity(self.isHovered ? 1.0 : 0.7)
    }
}

// MARK: - TokenTrackingRow

struct TokenTrackingRow: View {
    // MARK: Internal

    var tokenTrackingManager: TokenTrackingManager

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 12))
                        .foregroundColor(self.textColor)
                        .frame(width: 16)

                    Text("Token Tracking")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(self.textColor)

                    Spacer()

                    if self.tokenMode != .disabled {
                        HStack(spacing: 6) {
                            TokenRingView(
                                percentage: self.tokenTrackingManager.sessionPercentage,
                                label: "S",
                                size: 16,
                                strokeWidth: 2,
                            )
                            TokenRingView(
                                percentage: self.tokenTrackingManager.weeklyPercentage,
                                label: "W",
                                size: 16,
                                strokeWidth: 2,
                            )
                        }
                    }

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered || self.isExpanded ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    self.modeSelector
                    if self.tokenMode == .api {
                        self.apiSettings
                        self.displaySettings
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
                .padding(.trailing, 28)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Private

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var tokenMode: TokenTrackingMode = AppSettings.tokenTrackingMode
    @State private var showRingsMinimized: Bool = AppSettings.tokenShowRingsMinimized
    @State private var ringDisplay: RingDisplay = AppSettings.tokenMinimizedRingDisplay
    @State private var showResetTime: Bool = AppSettings.tokenShowResetTime
    @State private var useCLIOAuth: Bool = AppSettings.tokenUseCLIOAuth
    @State private var sessionKey: String = TokenTrackingManager.shared.loadSessionKey() ?? ""

    private var textColor: Color {
        .white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7)
    }

    private var modeSelector: some View {
        Picker("Mode", selection: self.$tokenMode) {
            ForEach(TokenTrackingMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: self.tokenMode) { _, newValue in
            AppSettings.tokenTrackingMode = newValue
            Task(name: "token-refresh") {
                await self.tokenTrackingManager.refresh()
            }
        }
    }

    private var apiSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: self.$useCLIOAuth) {
                Text("Use CLI OAuth")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: self.useCLIOAuth) { _, newValue in
                AppSettings.tokenUseCLIOAuth = newValue
                Task(name: "token-refresh") {
                    await self.tokenTrackingManager.refresh()
                }
            }

            if !self.useCLIOAuth {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    SecureField("Paste session key", text: self.$sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            self.tokenTrackingManager.saveSessionKey(self.sessionKey.isEmpty ? nil : self.sessionKey)
                            Task(name: "token-refresh") {
                                await self.tokenTrackingManager.refresh()
                            }
                        }
                }
            }
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show when minimized", isOn: self.$showRingsMinimized)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: self.showRingsMinimized) { _, newValue in
                        AppSettings.tokenShowRingsMinimized = newValue
                    }

                if self.showRingsMinimized {
                    Picker("Display", selection: self.$ringDisplay) {
                        ForEach(RingDisplay.allCases, id: \.self) { display in
                            Text(display.rawValue).tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.leading, 20)
                    .onChange(of: self.ringDisplay) { _, newValue in
                        AppSettings.tokenMinimizedRingDisplay = newValue
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show reset time", isOn: self.$showResetTime)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: self.showResetTime) { _, newValue in
                        AppSettings.tokenShowResetTime = newValue
                    }

                if self.showResetTime, let resetTime = self.tokenTrackingManager.sessionResetTime {
                    Text("Resets \(resetTime.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.green)
                        .padding(.leading, 20)
                }
            }
        }
    }
}
