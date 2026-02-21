//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import SwiftUI

// MARK: - ClaudeInstancesView

struct ClaudeInstancesView: View {
    // MARK: Internal

    /// Session monitor is @Observable, so SwiftUI automatically tracks property access
    var sessionMonitor: ClaudeSessionMonitor

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    var body: some View {
        if self.sessionMonitor.instances.isEmpty {
            self.emptyState
        } else {
            self.instancesList
        }
    }

    // MARK: Private

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        self.sessionMonitor.instances.sorted { lhs, rhs in
            let priorityLhs = self.phasePriority(lhs.phase)
            let priorityRhs = self.phasePriority(rhs.phase)
            if priorityLhs != priorityRhs {
                return priorityLhs < priorityRhs
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateLhs = lhs.lastUserMessageDate ?? lhs.lastActivity
            let dateRhs = rhs.lastUserMessageDate ?? rhs.lastActivity
            return dateLhs > dateRhs
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(self.sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        onFocus: { self.focusSession(session) },
                        onChat: { self.openChat(session) },
                        onArchive: { self.archiveSession(session) },
                        onApprove: { self.approveSession(session) },
                        onReject: { self.rejectSession(session) },
                    )
                    .id(session.stableID)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval,
             .processing,
             .compacting: 0
        case .waitingForInput: 1
        case .idle,
             .ended: 2
        }
    }

    private func focusSession(_ session: SessionState) {
        Task(name: "focus-terminal") {
            if let pid = session.pid {
                let success = await TerminalFocuser.shared.focusTerminal(forClaudePID: pid)
                if success { return }
            }
            _ = await TerminalFocuser.shared.focusTerminal(forWorkingDirectory: session.cwd)
        }
    }

    private func openChat(_ session: SessionState) {
        self.viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        self.sessionMonitor.approvePermission(sessionID: session.sessionID)
    }

    private func rejectSession(_ session: SessionState) {
        self.sessionMonitor.denyPermission(sessionID: session.sessionID, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        self.sessionMonitor.archiveSession(sessionID: session.sessionID)
    }
}

// MARK: - InstanceRow

struct InstanceRow: View {
    // MARK: Internal

    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            self.mainRow

            if self.isEditing {
                SessionLabelEditor(sessionID: self.session.sessionID)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.isEditing)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(self.isHovered ? Color.white.opacity(0.06) : Color.clear),
        )
        .onHover { self.isHovered = $0 }
        .onRightClick {
            withAnimation {
                if !self.isEditing {
                    self.editingName = self.displayTitle
                }
                self.isEditing.toggle()
            }
        }
        .onChange(of: self.isEditing) { _, newValue in
            if !newValue {
                self.saveName()
            }
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editingName = ""
    @FocusState private var isTitleFocused: Bool

    private let metadataManager = SessionMetadataManager.shared
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    private var displayTitle: String {
        self.metadataManager.name(for: self.session.sessionID) ?? self.session.displayTitle
    }

    private var isWaitingForApproval: Bool {
        self.session.phase.isWaitingForApproval
    }

    private var isInteractiveTool: Bool {
        guard let toolName = self.session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var phaseStatusText: String {
        switch self.session.phase {
        case .processing: "Processing..."
        case .compacting: "Compacting..."
        case .waitingForInput: "Ready"
        case .waitingForApproval: "Waiting for approval"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    private var mainRow: some View {
        HStack(spacing: 0) {
            if let color = self.metadataManager.color(for: self.session.sessionID) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }

            HStack(alignment: .center, spacing: 10) {
                self.stateIndicator
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if self.isEditing {
                            TextField("Session name", text: self.$editingName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .focused(self.$isTitleFocused)
                                .onSubmit {
                                    withAnimation { self.isEditing = false }
                                }
                                .onAppear { self.isTitleFocused = true }
                        } else {
                            Text(self.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }

                        if let usage = self.session.usage {
                            Text(usage.formattedTotal)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }

                    if self.isWaitingForApproval, let toolName = self.session.pendingToolName {
                        HStack(spacing: 4) {
                            Text(MCPToolFormatter.formatToolName(toolName))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(TerminalColors.amber.opacity(0.9))
                            if self.isInteractiveTool {
                                Text("Needs your input")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            } else if let input = self.session.pendingToolInput {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                    } else if let role = self.session.lastMessageRole {
                        switch role {
                        case "tool":
                            HStack(spacing: 4) {
                                if let toolName = self.session.lastToolName {
                                    Text(MCPToolFormatter.formatToolName(toolName))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                if let input = self.session.lastMessage {
                                    Text(input)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                            }
                        case "user":
                            HStack(spacing: 4) {
                                Text("You:")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                if let msg = self.session.lastMessage {
                                    Text(msg)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                            }
                        default:
                            if let msg = self.session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    } else if let lastMsg = self.session.lastMessage {
                        Text(lastMsg)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    } else {
                        Text(self.phaseStatusText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                Spacer(minLength: 0)

                if self.isWaitingForApproval && self.isInteractiveTool {
                    HStack(spacing: 8) {
                        IconButton(icon: "bubble.left") { self.onChat() }
                        if self.session.pid != nil {
                            TerminalButton(isEnabled: true) { self.onFocus() }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if self.isWaitingForApproval {
                    InlineApprovalButtons(
                        onChat: self.onChat,
                        onApprove: self.onApprove,
                        onReject: self.onReject,
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    HStack(spacing: 8) {
                        IconButton(icon: "bubble.left") { self.onChat() }
                        if self.session.pid != nil {
                            IconButton(icon: "terminal") { self.onFocus() }
                        }
                        if self.session.phase == .idle || self.session.phase == .waitingForInput {
                            IconButton(icon: "archivebox") { self.onArchive() }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.leading, self.metadataManager.color(for: self.session.sessionID) != nil ? 4 : 8)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !self.isEditing { self.onChat() }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.isWaitingForApproval)
    }

    @ViewBuilder private var stateIndicator: some View {
        switch self.session.phase {
        case .processing,
             .compacting:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(self.claudeOrange)
            }
        case .waitingForApproval:
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.spinnerSymbols.count
                Text(self.spinnerSymbols[phase])
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(TerminalColors.amber)
            }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle,
             .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

    private func saveName() {
        let trimmed = self.editingName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == self.session.displayTitle {
            self.metadataManager.setName(nil, for: self.session.sessionID)
        } else {
            self.metadataManager.setName(trimmed, for: self.session.sessionID)
        }
    }
}

// MARK: - InlineApprovalButtons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    // MARK: Internal

    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                self.onChat()
            }
            .opacity(self.showChatButton ? 1 : 0)
            .scaleEffect(self.showChatButton ? 1 : 0.8)

            Button {
                self.onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showDenyButton ? 1 : 0)
            .scaleEffect(self.showDenyButton ? 1 : 0.8)

            Button {
                self.onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showAllowButton ? 1 : 0)
            .scaleEffect(self.showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                self.showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                self.showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                self.showAllowButton = true
            }
        }
    }

    // MARK: Private

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
}

// MARK: - IconButton

struct IconButton: View {
    // MARK: Internal

    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            self.action()
        } label: {
            Image(systemName: self.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(self.isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(self.isHovered ? Color.white.opacity(0.1) : Color.clear),
                )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

// MARK: - CompactTerminalButton

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(self.isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TerminalButton

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(self.isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Click Modifier

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay {
            RightClickDetector(action: action)
        }
    }
}

// MARK: - RightClickDetector

struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> RightClickNSView {
        RightClickNSView(action: self.action)
    }

    func updateNSView(_ nsView: RightClickNSView, context _: Context) {
        nsView.action = self.action
    }
}

// MARK: - RightClickNSView

final class RightClickNSView: NSView {
    // MARK: Lifecycle

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Internal

    var action: () -> Void

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            let locationInView = convert(event.locationInWindow, from: nil)

            if bounds.contains(locationInView) {
                self.action()
                return nil
            }
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    // MARK: Private

    private var monitor: Any?
}
