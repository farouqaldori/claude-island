//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

/// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14)),
)

// MARK: - NotchView

// swiftlint:disable:next type_body_length
struct NotchView: View {
    // MARK: Lifecycle

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: Internal

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                self.notchLayout
                    .frame(
                        maxWidth: self.viewModel.status == .opened
                            ? self.notchSize.width
                            : (self.showClosedActivity ? self.closedContentWidth : nil),
                        alignment: .top,
                    )
                    .padding(
                        .horizontal,
                        self.viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom,
                    )
                    .padding([.horizontal, .bottom], self.viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(self.currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, self.topCornerRadius)
                    }
                    .shadow(
                        color: (self.viewModel.status == .opened || self.isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6,
                    )
                    .frame(
                        maxWidth: self.viewModel.status == .opened
                            ? self.notchSize.width
                            : (self.showClosedActivity ? self.closedContentWidth : nil),
                        maxHeight: self.viewModel.status == .opened ? self.notchSize.height : nil,
                        alignment: .top,
                    )
                    .animation(self.viewModel.status == .opened ? self.openAnimation : self.closeAnimation, value: self.viewModel.status)
                    .animation(self.openAnimation, value: self.notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: self.activityCoordinator.expandingActivity)
                    .animation(.smooth, value: self.hasPendingPermission)
                    .animation(.smooth, value: self.hasWaitingForInput)
                    .animation(.smooth, value: self.accessibilityManager.shouldShowPermissionWarning)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: self.isBouncing)
                    .animation(.smooth, value: self.clawdAlwaysVisible)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            self.isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if self.viewModel.status != .opened {
                            self.viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(self.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            self.sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            // Also keep visible if accessibility permission is missing (show warning)
            // Also keep visible if Clawd always visible is enabled
            if !self.viewModel.hasPhysicalNotch || self.needsAccessibilityWarning || self.clawdAlwaysVisible {
                self.isVisible = true
            }
        }
        .onChange(of: self.viewModel.status) { oldStatus, newStatus in
            self.handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: self.sessionMonitor.pendingInstances) { _, sessions in
            self.handlePendingSessionsChange(sessions)
        }
        .onChange(of: self.sessionMonitor.instances) { _, instances in
            self.handleProcessingChange()
            self.handleWaitingForInputChange(instances)
        }
        .onChange(of: self.accessibilityManager.shouldShowPermissionWarning) { _, shouldShow in
            // Keep notch visible while accessibility warning is shown
            if shouldShow {
                self.isVisible = true
                self.hideVisibilityTask?.cancel()
            } else {
                // Warning dismissed, trigger normal visibility logic
                self.handleProcessingChange()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                // Check accessibility permission when app becomes active
                // Catches the case where user grants permission in System Settings
                self.accessibilityManager.handleAppActivation()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self.clawdColor = AppSettings.clawdColor
                self.clawdAlwaysVisible = AppSettings.clawdAlwaysVisible
            }
        }
        .onChange(of: self.clawdAlwaysVisible) { _, newValue in
            if newValue {
                self.isVisible = true
                self.hideVisibilityTask?.cancel()
            } else {
                self.handleProcessingChange()
            }
        }
    }

    // MARK: Private

    /// Session monitor is @Observable, so we use @State for ownership
    @State private var sessionMonitor = ClaudeSessionMonitor()
    @State private var previousPendingIDs: Set<String> = []
    @State private var previousWaitingForInputIDs: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:] // sessionID -> when it entered waitingForInput
    @State private var isVisible = false
    @State private var isHovering = false
    @State private var isBouncing = false
    @State private var hideVisibilityTask: Task<Void, Never>?
    @State private var bounceTask: Task<Void, Never>?
    @State private var checkmarkHideTask: Task<Void, Never>?
    @State private var clawdColor: Color = AppSettings.clawdColor
    @State private var clawdAlwaysVisible: Bool = AppSettings.clawdAlwaysVisible
    @Namespace private var activityNamespace

    private var updateManager = UpdateManager.shared

    /// Singleton is @Observable, so SwiftUI automatically tracks property access
    private var activityCoordinator = NotchActivityCoordinator.shared

    /// Singleton for accessibility permission state
    private var accessibilityManager = AccessibilityPermissionManager.shared

    /// Singleton for token tracking state
    private var tokenTrackingManager = TokenTrackingManager.shared

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    /// Prefix indicating context was resumed (not a true "done" state)
    private let contextResumePrefix = "This session is being continued from a previous conversation"

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        self.sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        self.sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30 // Show checkmark for 30 seconds

        return self.sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableID] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    /// Sessions that are active (not ended) - includes idle sessions as they
    /// still represent running Claude processes
    private var activeSessions: [SessionState] {
        self.sessionMonitor.instances.filter { $0.phase != .ended }
    }

    /// Whether we have multiple active sessions to show dots for
    private var hasMultipleActiveSessions: Bool {
        self.activeSessions.count > 1
    }

    /// Whether accessibility permission is missing (show warning icon)
    private var needsAccessibilityWarning: Bool {
        self.accessibilityManager.shouldShowPermissionWarning
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: self.viewModel.deviceNotchRect.width,
            height: self.viewModel.deviceNotchRect.height,
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = self.hasPendingPermission ? 18 : 0

        // Accessibility warning indicator width
        let accessibilityWarningWidth: CGFloat = self.needsAccessibilityWarning ? 18 : 0

        // Token rings width (calculated separately to avoid recursion)
        let tokenRingsExtraWidth: CGFloat = {
            guard AppSettings.tokenTrackingMode != .disabled && AppSettings.tokenShowRingsMinimized else { return 0 }
            let display = AppSettings.tokenMinimizedRingDisplay
            let ringCount = (display.showSession ? 1 : 0) + (display.showWeekly ? 1 : 0)
            guard ringCount > 0 else { return 0 }
            let ringSize: CGFloat = 16
            return CGFloat(ringCount) * ringSize + CGFloat(ringCount - 1) * 4 + 12
        }()

        // Horizontal padding that needs to be outside the notch area
        let horizontalPadding = 2 * cornerRadiusInsets.closed.bottom

        // Expand for processing activity
        if self.activityCoordinator.expandingActivity.show {
            switch self.activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, self.closedNotchSize.height - 12) + 20
                return baseWidth + permissionIndicatorWidth + accessibilityWarningWidth + tokenRingsExtraWidth + horizontalPadding
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if self.hasPendingPermission {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + permissionIndicatorWidth + accessibilityWarningWidth + tokenRingsExtraWidth +
                horizontalPadding
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if self.hasWaitingForInput {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + accessibilityWarningWidth + tokenRingsExtraWidth + horizontalPadding
        }

        // Expand for multiple active sessions to accommodate session state dots
        // Uses symmetric expansion (sideWidth on both left and right) like processing
        if self.hasMultipleActiveSessions {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + accessibilityWarningWidth + tokenRingsExtraWidth + horizontalPadding
        }

        // Expand just for accessibility warning (when no other activity)
        if self.needsAccessibilityWarning {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + accessibilityWarningWidth + tokenRingsExtraWidth + horizontalPadding
        }

        // Expand for Clawd always visible (when no other activity)
        if self.clawdAlwaysVisible {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + tokenRingsExtraWidth + horizontalPadding
        }

        // Expand just for token rings (when no other activity)
        if tokenRingsExtraWidth > 0 {
            return 2 * max(0, self.closedNotchSize.height - 12) + 20 + tokenRingsExtraWidth + horizontalPadding
        }

        return 0
    }

    private var notchSize: CGSize {
        switch self.viewModel.status {
        case .closed,
             .popping:
            self.closedNotchSize
        case .opened:
            self.viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        self.closedNotchSize.width + self.expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        self.viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        self.viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: self.topCornerRadius,
            bottomCornerRadius: self.bottomCornerRadius,
        )
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        self.activityCoordinator.expandingActivity.show && self.activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, waiting for input, accessibility warning, always visible, or token
    /// rings)
    private var showClosedActivity: Bool {
        self.isProcessing || self.hasPendingPermission || self.hasWaitingForInput
            || self.hasMultipleActiveSessions || self.needsAccessibilityWarning || self.clawdAlwaysVisible
            || self.shouldShowTokenRingsMinimized
    }

    private var sideWidth: CGFloat {
        max(0, self.closedNotchSize.height - 12) + 10
    }

    private var shouldShowTokenRingsMinimized: Bool {
        AppSettings.tokenTrackingMode != .disabled && AppSettings.tokenShowRingsMinimized
    }

    private var shouldShowTokenRingsExpanded: Bool {
        AppSettings.tokenTrackingMode != .disabled
    }

    private var tokenRingsWidth: CGFloat {
        guard self.shouldShowTokenRingsMinimized else { return 0 }
        let display = AppSettings.tokenMinimizedRingDisplay
        let ringCount = (display.showSession ? 1 : 0) + (display.showWeekly ? 1 : 0)
        guard ringCount > 0 else { return 0 }
        let ringSize: CGFloat = 16
        return CGFloat(ringCount) * ringSize + CGFloat(ringCount - 1) * 4
    }

    private var rightSideWidth: CGFloat {
        var width = self.sideWidth
        if self.shouldShowTokenRingsMinimized {
            width += self.tokenRingsWidth + 8
        }
        return width
    }

    @ViewBuilder private var minimizedTokenRings: some View {
        let display = AppSettings.tokenMinimizedRingDisplay
        TokenRingsOverlay(
            sessionPercentage: self.tokenTrackingManager.sessionPercentage,
            weeklyPercentage: self.tokenTrackingManager.weeklyPercentage,
            showSession: display.showSession,
            showWeekly: display.showWeekly,
            size: 16,
            strokeWidth: 2,
            showResetTime: AppSettings.tokenShowResetTime,
            sessionResetTime: self.tokenTrackingManager.sessionResetTime,
        )
    }

    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            self.headerRow
                .frame(height: max(24, self.closedNotchSize.height))

            // Main content only when opened
            if self.viewModel.status == .opened {
                self.contentView
                    .frame(width: self.notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15)),
                        ),
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional indicators (only when minimized - when opened, crab moves to openedHeaderContent)
            if self.showClosedActivity && self.viewModel.status != .opened {
                HStack(spacing: 4) {
                    ClaudeCrabIcon(size: 14, color: self.clawdColor, animateLegs: self.isProcessing)
                        .matchedGeometryEffect(id: "crab", in: self.activityNamespace, isSource: self.viewModel.status != .opened)

                    // Permission indicator (prompt) - waiting for input shows checkmark on right
                    if self.hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: self.clawdColor)
                            .matchedGeometryEffect(id: "status-indicator", in: self.activityNamespace, isSource: true)
                    }

                    // Accessibility warning indicator (amber) - tap to re-check permission
                    if self.needsAccessibilityWarning {
                        Button {
                            self.accessibilityManager.handleAppActivation()
                        } label: {
                            AccessibilityWarningIcon(size: 14, color: TerminalColors.amber)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: self.sideWidth + (self.hasPendingPermission ? 18 : 0) + (self.needsAccessibilityWarning ? 18 : 0))
            }

            // Center content
            if self.viewModel.status == .opened {
                // Opened: show header content
                self.openedHeaderContent
            } else if !self.showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: self.closedNotchSize.width - 20)
            } else {
                // Closed with activity: flexible spacer with session dots (with optional bounce)
                HStack(spacing: 0) {
                    Spacer(minLength: 20)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, self.isBouncing ? 16 : 0)
                    // Session state dots (only when closed with multiple active sessions)
                    if self.hasMultipleActiveSessions {
                        SessionStateDots(sessions: self.activeSessions)
                            .padding(.leading, 6)
                    }
                }
            }

            // Right side - spinner when processing/pending, checkmark when waiting for input,
            // token rings when enabled (only when minimized - when opened these move to openedHeaderContent)
            if self.showClosedActivity && self.viewModel.status != .opened {
                HStack(spacing: 4) {
                    if self.isProcessing || self.hasPendingPermission {
                        ProcessingSpinner()
                            .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: true)
                    } else if self.hasWaitingForInput {
                        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: true)
                    }

                    // Token rings when minimized and enabled
                    if self.shouldShowTokenRingsMinimized {
                        self.minimizedTokenRings
                            .matchedGeometryEffect(id: "token-rings", in: self.activityNamespace, isSource: self.viewModel.status != .opened)
                    }
                }
                .frame(width: self.rightSideWidth, alignment: .trailing)
                .padding(.trailing, 4)
            } else if self.viewModel.status != .opened && self.shouldShowTokenRingsMinimized {
                // Token rings even when no other activity is shown
                self.minimizedTokenRings
                    .matchedGeometryEffect(id: "token-rings", in: self.activityNamespace, isSource: true)
                    .padding(.trailing, 4)
            }
        }
        .frame(
            width: self.viewModel.status == .opened ? self.notchSize.width - 24 : nil,
            height: self.closedNotchSize.height,
        )
    }

    // MARK: - Opened Header Content

    private var openedHeaderContent: some View {
        HStack(spacing: 0) {
            // Always show crab in opened state - animates from headerRow via matchedGeometryEffect
            ClaudeCrabIcon(size: 14, color: self.clawdColor, animateLegs: self.isProcessing)
                .matchedGeometryEffect(id: "crab", in: self.activityNamespace, isSource: self.viewModel.status == .opened)
                .padding(.leading, 8)

            Spacer()

            // Right-side elements grouped together
            HStack(spacing: 12) {
                // Activity indicator
                if self.isProcessing || self.hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: self.viewModel.status == .opened)
                } else if self.hasWaitingForInput {
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: self.activityNamespace, isSource: self.viewModel.status == .opened)
                }

                // Token rings in expanded header
                if self.shouldShowTokenRingsExpanded {
                    self.minimizedTokenRings
                        .matchedGeometryEffect(id: "token-rings", in: self.activityNamespace, isSource: self.viewModel.status == .opened)
                }

                // Menu toggle
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.viewModel.toggleMenu()
                        if self.viewModel.contentType == .menu {
                            self.updateManager.markUpdateSeen()
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: self.viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())

                        // Green dot for unseen update
                        if self.updateManager.hasUnseenUpdate && self.viewModel.contentType != .menu {
                            Circle()
                                .fill(TerminalColors.green)
                                .frame(width: 6, height: 6)
                                .offset(x: -2, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content View (Opened State)

    private var contentView: some View {
        Group {
            switch self.viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel,
                )
            case .menu:
                NotchMenuView(viewModel: self.viewModel)
            case let .chat(session):
                ChatView(
                    sessionID: session.sessionID,
                    initialSession: session,
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel,
                )
            }
        }
        .frame(width: self.notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if self.isAnyProcessing || self.hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            self.activityCoordinator.showActivity(type: .claude)
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
        } else if self.hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            self.activityCoordinator.hideActivity()
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
        } else if self.clawdAlwaysVisible {
            // Keep visible when always-visible is enabled, but hide processing spinner
            self.activityCoordinator.hideActivity()
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
        } else {
            // Hide activity when done
            self.activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if self.viewModel.status == .closed && self.viewModel.hasPhysicalNotch {
                self.hideVisibilityTask?.cancel()
                self.hideVisibilityTask = Task(name: "hide-notch-processing") {
                    try? await Task.sleep(for: .seconds(0.5))
                    guard !Task.isCancelled else { return }
                    if !self.isAnyProcessing && !self.hasPendingPermission && !self.hasWaitingForInput
                        && !self.hasMultipleActiveSessions && !self.needsAccessibilityWarning
                        && !self.clawdAlwaysVisible && self.viewModel.status == .closed {
                        self.isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened,
             .popping:
            self.isVisible = true
            self.hideVisibilityTask?.cancel()
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if self.viewModel.openReason == .click || self.viewModel.openReason == .hover {
                self.waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard self.viewModel.hasPhysicalNotch else { return }
            // Don't hide when always-visible is enabled
            guard !self.clawdAlwaysVisible else { return }
            self.hideVisibilityTask?.cancel()
            self.hideVisibilityTask = Task(name: "hide-notch-close") {
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled else { return }
                if self.viewModel.status == .closed && !self.isAnyProcessing && !self.hasPendingPermission
                    && !self.hasWaitingForInput && !self.hasMultipleActiveSessions && !self.needsAccessibilityWarning
                    && !self.clawdAlwaysVisible && !self.activityCoordinator.expandingActivity.show {
                    self.isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIDs = Set(sessions.map(\.stableID))
        let newPendingIDs = currentIDs.subtracting(self.previousPendingIDs)

        if !newPendingIDs.isEmpty &&
            self.viewModel.status == .closed &&
            !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            self.viewModel.notchOpen(reason: .notification)
        }

        self.previousPendingIDs = currentIDs
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIDs = Set(waitingForInputSessions.map(\.stableID))
        let newWaitingIDs = currentIDs.subtracting(self.previousWaitingForInputIDs)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIDs.contains(session.stableID) {
            waitingForInputTimestamps[session.stableID] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIDs = Set(waitingForInputTimestamps.keys).subtracting(currentIDs)
        for staleID in staleIDs {
            self.waitingForInputTimestamps.removeValue(forKey: staleID)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIDs.isEmpty {
            // Get the sessions that just entered waitingForInput, excluding context resumes
            let newlyWaitingSessions = waitingForInputSessions.filter { session in
                guard newWaitingIDs.contains(session.stableID) else { return false }

                // Don't alert for context resume (ran out of context window)
                if let lastMessage = session.lastMessage,
                   lastMessage.hasPrefix(contextResumePrefix) {
                    return false
                }
                return true
            }

            // Skip all alerts if only context resumes remain
            guard !newlyWaitingSessions.isEmpty else {
                self.previousWaitingForInputIDs = currentIDs
                return
            }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task(name: "notification-sound") {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            self.bounceTask?.cancel()
            self.isBouncing = true
            self.bounceTask = Task(name: "bounce-animation") {
                // Bounce back after a short delay
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                self.isBouncing = false
            }

            // Schedule hiding the checkmark after 30 seconds
            self.checkmarkHideTask?.cancel()
            self.checkmarkHideTask = Task(name: "checkmark-hide") {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                // Trigger a UI update to re-evaluate hasWaitingForInput
                self.handleProcessingChange()
            }
        }

        self.previousWaitingForInputIDs = currentIDs
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if sound should play based on suppression settings
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        let suppressionMode = AppSettings.soundSuppression

        // If suppression is disabled, always play sound
        if suppressionMode == .never {
            return true
        }

        // Suppress if Claude Island is active
        if NSApplication.shared.isActive {
            return false
        }

        // Check each session against the suppression mode
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus/visibility, assume should play
                return true
            }

            switch suppressionMode {
            case .never:
                // Already handled above, but included for completeness
                return true

            case .whenFocused:
                // Suppress if the session's terminal is focused
                let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPID: pid)
                if !isFocused {
                    return true
                }

            case .whenVisible:
                // Suppress if the session's terminal window is ≥50% visible
                let isVisible = await TerminalVisibilityDetector.isSessionTerminalVisible(sessionPID: pid)
                if !isVisible {
                    return true
                }
            }
        }

        // All sessions are suppressed
        return false
    }
}
