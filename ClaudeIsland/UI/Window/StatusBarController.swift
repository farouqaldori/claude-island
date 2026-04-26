//
//  StatusBarController.swift
//  ClaudeIsland
//
//  Manages the status bar icon and floating panel for StatusBar display mode
//

import AppKit
import Combine
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem?
    private var statusBarButton: NSStatusBarButton?

    private var panel: StatusBarPanel?
    private var panelHostingController: NSHostingController<StatusBarContentView>?
    private var panelEventMonitor: Any?

    private let viewModel: NotchViewModel
    private var cancellables = Set<AnyCancellable>()

    private var isProcessing: Bool = false
    private var hasPendingPermission: Bool = false
    private var isReadyForInput: Bool = false
    private var isCompacting: Bool = false

    // Track previous states for notification triggers
    private var wasProcessing: Bool = false
    private var wasCompacting: Bool = false

    // Animation timer for pulsing effect
    private var animationTimer: Timer?
    private var pulsePhase: Double = 0

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        teardown()
    }

    // MARK: - Setup

    func setup() {
        // Use squareLength for better visibility with status indicators
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem = statusItem,
              let button = statusItem.button else {
            return
        }

        statusBarButton = button
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: .leftMouseDown)

        // Set initial icon
        updateIcon()

        // Start animation timer for processing state
        startAnimationTimer()

        // Observe session state changes
        observeSessionState()
    }

    func teardown() {
        hidePanel()
        animationTimer?.invalidate()
        animationTimer = nil

        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }

        panel?.close()
        panel = nil
        panelHostingController = nil
    }

    // MARK: - Animation Timer

    private func startAnimationTimer() {
        // Flowing animation requires continuous updates
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only update when animation states are active
            if self.isProcessing || self.hasPendingPermission || self.isCompacting || self.isReadyForInput {
                self.pulsePhase += 0.02
                if self.pulsePhase > 1.0 {
                    self.pulsePhase = 0
                }
                DispatchQueue.main.async {
                    self.updateIconAnimated()
                }
            }
        }
    }

    // MARK: - Session State Observation

    private func observeSessionState() {
        // Observe the shared session store to update icon state
        Task { @MainActor in
            for await sessions in SessionStore.shared.sessionsPublisher.values {
                updateState(from: sessions)
            }
        }
    }

    private func updateState(from sessions: [SessionState]) {
        // Track state transitions for notifications
        let previouslyProcessing = wasProcessing
        let previouslyCompacting = wasCompacting

        // Update current states
        isProcessing = sessions.contains { $0.phase == .processing }
        isCompacting = sessions.contains { $0.phase == .compacting }
        hasPendingPermission = sessions.contains { $0.phase.isWaitingForApproval }
        isReadyForInput = sessions.contains { $0.phase == .waitingForInput }

        // Store for next comparison
        wasProcessing = isProcessing
        wasCompacting = isCompacting

        // Detect task completion: transition from processing/compacting to ready
        // Only send notification if we were actively processing and now are ready
        if (previouslyProcessing || previouslyCompacting) && !isProcessing && !isCompacting && isReadyForInput {
            // Find the session that just completed to get its title
            let completedSession = sessions.first { $0.phase == .waitingForInput }
            sendTaskCompletionNotification(sessionTitle: completedSession?.displayTitle)
        }

        updateIcon()
    }

    private func sendTaskCompletionNotification(sessionTitle: String?) {
        Task {
            await SystemNotificationService.shared.sendTaskCompletionNotification(sessionTitle: sessionTitle)
        }
    }

    // MARK: - Icon Management

    private func updateIcon() {
        pulsePhase = 0
        updateIconAnimated()
    }

    private func updateIconAnimated() {
        guard let button = statusBarButton else { return }

        // Determine the current status
        let status: StatusBarStatus
        if hasPendingPermission {
            status = .permissionWaiting
        } else if isCompacting {
            status = .compacting
        } else if isProcessing {
            status = .processing
        } else if isReadyForInput {
            status = .ready
        } else {
            status = .idle
        }

        // Create the icon view with current pulse phase
        let iconView = StatusBarIconView(
            status: status,
            pulsePhase: pulsePhase
        )

        // Hosting view for SwiftUI icon
        let hostingView = NSHostingView(rootView: iconView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 32, height: 26)

        // Use NSView's bitmapImageRepForCachingDisplay
        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep!)

        // Create image from bitmap rep
        let image = NSImage()
        image.size = NSSize(width: 32, height: 26)
        image.addRepresentation(rep!)

        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
    }

    // MARK: - Click Handling

    @objc private func handleStatusItemClick() {
        if panel?.isVisible == true {
            hidePanel()
            return
        }
        guard let screen = statusItem?.button?.window?.screen ?? NSScreen.main else { return }
        showPanel(on: screen)
    }

    // MARK: - Panel Management

    private func showPanel(on screen: NSScreen) {
        guard let statusItem = statusItem,
              let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let panelSize = NSSize(width: 400, height: 500)

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let preferredX = buttonRectOnScreen.midX - panelSize.width / 2
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - panelSize.width - 8
        let originX = max(minX, min(preferredX, maxX))

        // Reserve at least 24pt for the menu bar even when visibleFrame == frame
        // (which happens on a fullscreen Space where the menu bar is auto-hiding).
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let topY = screen.frame.maxY - menuBarHeight - 4
        let originY = topY - panelSize.height

        let frame = NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize)

        if panel == nil {
            let host = NSHostingController(rootView: StatusBarContentView(viewModel: viewModel))
            host.view.wantsLayer = true
            let p = StatusBarPanel(contentRect: frame)
            p.contentViewController = host
            panel = p
            panelHostingController = host
        }

        guard let panel = panel else { return }

        // Set frame only once at display time; panel does not follow the menu bar afterwards.
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        addPanelEventMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removePanelEventMonitor()
    }

    private func addPanelEventMonitor() {
        panelEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let mouseScreenLocation = NSEvent.mouseLocation
            if !panel.frame.contains(mouseScreenLocation) {
                self.hidePanel()
            }
        }
    }

    private func removePanelEventMonitor() {
        if let monitor = panelEventMonitor {
            NSEvent.removeMonitor(monitor)
            panelEventMonitor = nil
        }
    }
}

// MARK: - Status Bar Status Enum

enum StatusBarStatus {
    case idle           // No active session
    case processing     // Claude is processing
    case compacting     // Compressing context
    case permissionWaiting  // Waiting for user permission approval
    case ready          // Waiting for user input

    var color: Color {
        switch self {
        case .idle:
            return .gray.opacity(0.6)
        case .processing:
            return TerminalColors.blue
        case .compacting:
            return TerminalColors.amber
        case .permissionWaiting:
            return Color(red: 0.85, green: 0.47, blue: 0.34)  // Orange-red
        case .ready:
            return TerminalColors.green
        }
    }

    var icon: String {
        switch self {
        case .idle:
            return ""
        case .processing:
            return "ellipsis.circle"
        case .compacting:
            return "arrow.triangle.2.circlepath"
        case .permissionWaiting:
            return "hand.raised.fill"
        case .ready:
            return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .idle:
            return ""
        case .processing:
            return LString.processing.localized
        case .compacting:
            return LString.compacting.localized
        case .permissionWaiting:
            return LString.waitingForApproval.localized
        case .ready:
            return LString.ready.localized
        }
    }
}

// MARK: - Status Bar Icon View

struct StatusBarIconView: View {
    let status: StatusBarStatus
    let pulsePhase: Double

    var body: some View {
        ZStack(alignment: .center) {
            // Outer rectangle frame - status indicator
            StatusBarFrame(status: status, pulsePhase: pulsePhase)

            // Center crab icon (scaled up and offset down to avoid head overlapping with frame)
            ClaudeCrabIcon(size: 16, animateLegs: status == .processing || status == .compacting)
                .offset(y: 3)  // Move down 3 pixels, head stays on top, legs can overlap with frame
        }
        .frame(width: 28, height: 22)
    }
}

// MARK: - Status Bar Frame (Rectangle status indicator)

struct StatusBarFrame: View {
    let status: StatusBarStatus
    let pulsePhase: Double

    // Rectangle frame dimensions (matching larger crab)
    private let frameWidth: CGFloat = 26
    private let frameHeight: CGFloat = 20
    private let cornerRadius: CGFloat = 3

    // Flowing line parameters
    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            // Base static border
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: lineWidth)
                .frame(width: frameWidth, height: frameHeight)

            // Flowing progress line (processing/compacting states)
            if status == .processing || status == .compacting {
                // dashPhase makes dashed line "flow" along the rectangle frame
                // Offset changes continuously to create flowing effect
                let phase = pulsePhase * 92  // 92 = rectangle perimeter 2*(26+20)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        progressColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth + 1,
                            lineCap: .round,
                            dash: [8, 84],  // 8px bright segment + 84px dark segment = total 92px
                            dashPhase: phase
                        )
                    )
                    .frame(width: frameWidth, height: frameHeight)
            }

            // Task complete state: green fill + border
            if status == .ready {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(TerminalColors.green.opacity(0.25))
                    .frame(width: frameWidth, height: frameHeight)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(TerminalColors.green, lineWidth: lineWidth + 0.5)
                    .frame(width: frameWidth, height: frameHeight)
            }

            // Permission waiting state: flashing border
            if status == .permissionWaiting {
                let flashOpacity = 0.5 + 0.5 * sin(pulsePhase * 4 * .pi)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(red: 0.85, green: 0.47, blue: 0.34), lineWidth: lineWidth + 1)
                    .opacity(flashOpacity)
                    .frame(width: frameWidth, height: frameHeight)
            }
        }
    }

    private var borderColor: Color {
        switch status {
        case .idle:
            return .clear  // Transparent when idle
        case .processing:
            return TerminalColors.blue.opacity(0.2)  // Light blue base frame
        case .compacting:
            return TerminalColors.amber.opacity(0.2)
        case .permissionWaiting:
            return Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.3)
        case .ready:
            return TerminalColors.green.opacity(0.5)
        }
    }

    private var progressColor: Color {
        switch status {
        case .processing:
            return TerminalColors.blue
        case .compacting:
            return TerminalColors.amber
        default:
            return .clear
        }
    }
}