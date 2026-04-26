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
        // 流动动画需要持续更新
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 只有在需要动画的状态才更新
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
        isProcessing = sessions.contains { $0.phase == .processing }
        isCompacting = sessions.contains { $0.phase == .compacting }
        hasPendingPermission = sessions.contains { $0.phase.isWaitingForApproval }
        isReadyForInput = sessions.contains { $0.phase == .waitingForInput }

        updateIcon()
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
    case idle           // 无活跃 session
    case processing     // Claude 正在处理
    case compacting     // 正在压缩上下文
    case permissionWaiting  // 等待用户批准权限
    case ready          // 等待用户输入

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
            return "处理中"
        case .compacting:
            return "压缩中"
        case .permissionWaiting:
            return "等待批准"
        case .ready:
            return "就绪"
        }
    }
}

// MARK: - Status Bar Icon View

struct StatusBarIconView: View {
    let status: StatusBarStatus
    let pulsePhase: Double

    var body: some View {
        ZStack(alignment: .center) {
            // 外层矩形框 - 状态指示器
            StatusBarFrame(status: status, pulsePhase: pulsePhase)

            // 中间螃蟹图标（放大并向下偏移，避免头部与边框重叠）
            ClaudeCrabIcon(size: 16, animateLegs: status == .processing || status == .compacting)
                .offset(y: 3)  // 向下移动3像素，头部在上，腿部可与边框重叠
        }
        .frame(width: 28, height: 22)
    }
}

// MARK: - Status Bar Frame (矩形框状态指示器)

struct StatusBarFrame: View {
    let status: StatusBarStatus
    let pulsePhase: Double

    // 矩形框尺寸（配合更大的螃蟹）
    private let frameWidth: CGFloat = 26
    private let frameHeight: CGFloat = 20
    private let cornerRadius: CGFloat = 3

    // 流动线条参数
    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            // 底层静态边框
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: lineWidth)
                .frame(width: frameWidth, height: frameHeight)

            // 流动进度线（处理中/压缩中状态）
            if status == .processing || status == .compacting {
                // dashPhase 让虚线沿着矩形边框"流动"
                // 偏移量不断变化，产生流动效果
                let phase = pulsePhase * 92  // 92 = 矩形周长 2*(26+20)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        progressColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth + 1,
                            lineCap: .round,
                            dash: [8, 84],  // 8px亮段 + 84px暗段 = 总长92px
                            dashPhase: phase
                        )
                    )
                    .frame(width: frameWidth, height: frameHeight)
            }

            // 任务完成状态：绿色填充 + 边框
            if status == .ready {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(TerminalColors.green.opacity(0.25))
                    .frame(width: frameWidth, height: frameHeight)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(TerminalColors.green, lineWidth: lineWidth + 0.5)
                    .frame(width: frameWidth, height: frameHeight)
            }

            // 权限等待状态：闪烁边框
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
            return .clear  // 空闲时透明
        case .processing:
            return TerminalColors.blue.opacity(0.2)  // 淡蓝色底框
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