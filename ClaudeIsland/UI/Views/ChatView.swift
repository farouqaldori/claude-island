//
//  ChatView.swift
//  ClaudeIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import AppKit
import os
import SwiftUI

// swiftlint:disable file_length

// MARK: - ChatView

// swiftlint:disable:next type_body_length
struct ChatView: View {
    // MARK: Lifecycle

    init(sessionID: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionID = sessionID
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self.viewModel = viewModel
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionID)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    // MARK: Internal

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    let sessionID: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                self.chatHeader

                // Messages
                if self.isLoading {
                    self.loadingState
                } else if self.history.isEmpty {
                    self.emptyState
                } else {
                    self.messageList
                }

                // Approval bar, interactive prompt, or Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" {
                        // Interactive tools - show prompt to answer in terminal
                        self.interactivePromptBar
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity,
                            ))
                    } else {
                        self.approvalBar(tool: tool)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity,
                            ))
                    }
                } else {
                    self.inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: self.isWaitingForApproval)
        .animation(nil, value: self.viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !self.hasLoadedOnce else { return }
            self.hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionID: self.sessionID) {
                self.history = ChatHistoryManager.shared.history(for: self.sessionID)
                self.isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionID: self.sessionID, cwd: self.session.cwd)
            self.history = ChatHistoryManager.shared.history(for: self.sessionID)

            withAnimation(.easeOut(duration: 0.2)) {
                self.isLoading = false
            }
        }
        .onChange(of: self.chatManagerHistory) { _, newHistory in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            let countChanged = newHistory.count != self.history.count
            let lastItemChanged = newHistory.last?.id != self.history.last?.id
            // Always update - @Observable ensures we only get notified on real changes
            // This allows tool status updates (waitingForApproval -> running) to reflect
            if countChanged || lastItemChanged || newHistory != self.history {
                // Track new messages when autoscroll is paused
                if self.isAutoscrollPaused && newHistory.count > self.previousHistoryCount {
                    let addedCount = newHistory.count - self.previousHistoryCount
                    self.newMessageCount += addedCount
                    self.previousHistoryCount = newHistory.count
                }

                self.history = newHistory

                // Auto-scroll to bottom only if autoscroll is NOT paused
                if !self.isAutoscrollPaused && countChanged {
                    self.shouldScrollToBottom = true
                }

                // If we have data, skip loading state (handles view recreation)
                if self.isLoading && !newHistory.isEmpty {
                    self.isLoading = false
                }
            }
        }
        .onChange(of: self.chatManagerHistories) { _, newHistories in
            // Handle session removal (via /clear) - navigate back if session is gone
            if self.hasLoadedOnce && newHistories[self.sessionID] == nil {
                self.viewModel.exitChat()
            }
        }
        .onChange(of: self.sessionMonitor.instances) { _, sessions in
            if let updated = sessions.first(where: { $0.sessionID == sessionID }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = self.isWaitingForApproval
                self.session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    self.scrollToBottomTask?.cancel()
                    self.scrollToBottomTask = Task(name: "scroll-to-bottom") {
                        try? await Task.sleep(for: .seconds(0.3))
                        guard !Task.isCancelled else { return }
                        self.shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: self.canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !self.isInputFocused {
                self.focusInputTask?.cancel()
                self.focusInputTask = Task(name: "auto-focus-input") {
                    try? await Task.sleep(for: .seconds(0.1))
                    guard !Task.isCancelled else { return }
                    self.isInputFocused = true
                }
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            self.focusInputTask?.cancel()
            self.focusInputTask = Task(name: "focus-on-appear") {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                if self.canSendMessages {
                    self.isInputFocused = true
                }
            }
            // Install keyboard event monitor for Cmd+V paste
            self.installKeyEventMonitor()
        }
        .onDisappear {
            // Clean up key event monitor to prevent memory leaks
            self.removeKeyEventMonitor()
        }
    }

    // MARK: Private

    // MARK: - Keyboard Event Monitoring

    /// Logger for image paste operations
    private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ChatView")

    @State private var inputText = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading = true
    @State private var hasLoadedOnce = false
    @State private var shouldScrollToBottom = false
    @State private var isAutoscrollPaused = false
    @State private var newMessageCount = 0
    @State private var previousHistoryCount = 0
    @State private var isBottomVisible = true
    @State private var scrollToBottomTask: Task<Void, Never>?
    @State private var focusInputTask: Task<Void, Never>?
    @State private var pendingImage: NSImage?
    @State private var keyEventMonitor: Any?
    @FocusState private var isInputFocused: Bool

    // MARK: - Header

    @State private var isHeaderHovered = false

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    /// Access to chat history from @Observable manager for SwiftUI observation
    private var chatManagerHistory: [ChatHistoryItem] {
        ChatHistoryManager.shared.histories[self.sessionID] ?? []
    }

    /// Access to all histories from @Observable manager for session removal detection
    private var chatManagerHistories: [String: [ChatHistoryItem]] {
        ChatHistoryManager.shared.histories
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        self.session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        self.session.phase.approvalToolName
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        self.session.phase == .processing || self.session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageID: String {
        for item in self.history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Input Bar

    /// Can send messages only if session is in tmux
    private var canSendMessages: Bool {
        self.session.isInTmux && self.session.tty != nil
    }

    /// Whether there is content to send (text or image)
    private var canSendContent: Bool {
        !self.inputText.isEmpty || self.pendingImage != nil
    }

    private var chatHeader: some View {
        Button {
            self.viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(self.isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(self.session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(self.isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.isHeaderHovered ? Color.white.opacity(0.08) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [self.fadeColor.opacity(0.7), self.fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom,
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if self.isProcessing {
                        ProcessingIndicatorView(turnID: self.lastUserMessageID)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity,
                            ))
                    }

                    ForEach(self.history.reversed()) { item in
                        MessageItemView(item: item, sessionID: self.sessionID)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity,
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    self.pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && self.isAutoscrollPaused {
                    // User scrolled back to bottom
                    self.resumeAutoscroll()
                }
            }
            .onChange(of: self.shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    self.shouldScrollToBottom = false
                    self.resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if self.isAutoscrollPaused && self.newMessageCount > 0 {
                    NewMessagesIndicator(count: self.newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        self.resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity,
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: self.isAutoscrollPaused && self.newMessageCount > 0)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Image preview (if pending)
            if let image = self.pendingImage {
                self.imagePreview(image: image)
            }

            HStack(spacing: 10) {
                // Paste image button
                Button {
                    self.pasteImageFromClipboard()
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundColor(self.canSendMessages ? .white.opacity(0.6) : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!self.canSendMessages)
                .help("Paste image from clipboard")

                TextField(self.canSendMessages ? "Message Claude..." : "Open Claude Code in tmux to enable messaging", text: self.$inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(self.canSendMessages ? .white : .white.opacity(0.4))
                    .focused(self.$isInputFocused)
                    .disabled(!self.canSendMessages)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(self.canSendMessages ? 0.08 : 0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1),
                            ),
                    )
                    .onSubmit {
                        self.sendMessage()
                    }

                Button {
                    self.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(!self.canSendMessages || !self.canSendContent ? .white.opacity(0.2) : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(!self.canSendMessages || !self.canSendContent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [self.fadeColor.opacity(0), self.fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom,
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            isInTmux: self.session.isInTmux,
        ) { self.focusTerminal() }
    }

    // MARK: - Image Preview

    private func imagePreview(image: NSImage) -> some View {
        HStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 80)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1),
                )

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.pendingImage = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove image")

            Spacer()
        }
        .padding(.horizontal, 4)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal: .opacity,
        ))
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: self.session.pendingToolInput,
            onApprove: { self.approvePermission() },
            onDeny: { self.denyPermission() },
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        self.isAutoscrollPaused = true
        self.previousHistoryCount = self.history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        self.isAutoscrollPaused = false
        self.newMessageCount = 0
        self.previousHistoryCount = self.history.count
    }

    /// Install local event monitor for Cmd+V paste shortcut
    private func installKeyEventMonitor() {
        // Remove any existing monitor first
        self.removeKeyEventMonitor()

        self.keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Check for Cmd+V when input is focused
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" && self.isInputFocused {
                // Check if clipboard has image data
                let pasteboard = NSPasteboard.general
                if pasteboard.data(forType: .tiff) != nil || pasteboard.data(forType: .png) != nil {
                    self.pasteImageFromClipboard()
                    return nil // Consume the event
                }
            }
            return event // Pass through other events
        }
    }

    /// Remove the key event monitor
    private func removeKeyEventMonitor() {
        if let monitor = self.keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            self.keyEventMonitor = nil
        }
    }

    // MARK: - Image Handling

    /// Paste image from clipboard
    private func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general

        // Try to get image data from pasteboard
        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                self.pendingImage = image
            }
            return
        }

        if let pngData = pasteboard.data(forType: .png),
           let image = NSImage(data: pngData) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                self.pendingImage = image
            }
            return
        }

        // Try file URL for image files
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        self.pendingImage = image
                    }
                    return
                }
            }
        }

        Self.logger.debug("No image found in clipboard")
    }

    /// Save image to temporary directory and return the file path
    private func saveImageToTemp(_ image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:])
        else {
            Self.logger.error("Failed to convert image to PNG data")
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "claude-island-\(timestamp).png"
        let tempPath = NSTemporaryDirectory() + filename

        do {
            try pngData.write(to: URL(fileURLWithPath: tempPath))
            Self.logger.debug("Saved image to \(tempPath)")
            return tempPath
        } catch {
            Self.logger.error("Failed to save image to temp: \(error.localizedDescription)")
            return nil
        }
    }

    private func focusTerminal() {
        Task(name: "focus-terminal") {
            if let pid = session.pid {
                let success = await TerminalFocuser.shared.focusTerminal(forClaudePID: pid)
                if success { return }
            }
            _ = await TerminalFocuser.shared.focusTerminal(forWorkingDirectory: self.session.cwd)
        }
    }

    private func approvePermission() {
        self.sessionMonitor.approvePermission(sessionID: self.sessionID)
    }

    private func denyPermission() {
        self.sessionMonitor.denyPermission(sessionID: self.sessionID, reason: nil)
    }

    private func sendMessage() {
        let text = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = self.pendingImage

        // Need either text or image to send
        guard !text.isEmpty || image != nil else { return }

        // Try to save image first (if present)
        var imagePath: String?
        if let image {
            imagePath = self.saveImageToTemp(image)
            // If we only have an image (no text) and saving failed, don't proceed
            if text.isEmpty && imagePath == nil {
                Self.logger.warning("Image save failed and no text provided - not sending")
                return
            }
        }

        // Clear input state (only after confirming we have something to send)
        self.inputText = ""
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            self.pendingImage = nil
        }

        // Resume autoscroll when user sends a message
        self.resumeAutoscroll()
        self.shouldScrollToBottom = true

        // Build the message, including image path if present
        var messageToSend = text
        if let imagePath {
            // Prepend image path to message
            if text.isEmpty {
                messageToSend = imagePath
            } else {
                messageToSend = "\(imagePath) \(text)"
            }
        }

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task(name: "send-message") {
            await self.sendToSession(messageToSend)
        }
    }

    private func sendToSession(_ text: String) async {
        guard self.session.isInTmux else { return }
        guard let tty = session.tty else { return }

        if let target = await findTmuxTarget(tty: tty) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"],
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

// MARK: - MessageItemView

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionID: String

    var body: some View {
        switch self.item.type {
        case let .user(text):
            UserMessageView(text: text)
        case let .assistant(text):
            AssistantMessageView(text: text)
        case let .toolCall(tool):
            ToolCallView(tool: tool, sessionID: self.sessionID)
        case let .thinking(text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - UserMessageView

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(self.text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15)),
                )
        }
    }
}

// MARK: - AssistantMessageView

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // White dot indicator
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(self.text, color: .white.opacity(0.9), fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

// MARK: - ProcessingIndicatorView

struct ProcessingIndicatorView: View {
    // MARK: Lifecycle

    /// Use a turnID to select text consistently per user turn
    init(turnID: String = "") {
        // Use hash of turnID to pick base text consistently for this turn
        let index = abs(turnID.hashValue) % self.baseTexts.count
        self.baseText = self.baseTexts[index]
    }

    // MARK: Internal

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dotCount = (Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3) + 1
            HStack(alignment: .center, spacing: 6) {
                ProcessingSpinner()
                    .frame(width: 6)

                Text(self.baseText + String(repeating: ".", count: dotCount))
                    .font(.system(size: 13))
                    .foregroundColor(self.color)

                Spacer()
            }
        }
    }

    // MARK: Private

    private let baseTexts = ["Processing", "Working"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
    private let baseText: String
}

// MARK: - ToolCallView

struct ToolCallView: View {
    // MARK: Internal

    let tool: ToolCallItem
    let sessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.statusColor.opacity(self.tool.status == .running || self.tool.status == .waitingForApproval ? self.pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(self.tool.status) // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if self.tool.status == .running || self.tool.status == .waitingForApproval {
                            self.startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(self.tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(self.textColor)
                    .fixedSize()

                if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
                    let taskDesc = self.tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(self.tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(self.textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if self.tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = self.tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(self.textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(self.tool.name) && !self.tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(self.tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(self.textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(self.tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(self.textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if self.canExpand && self.tool.status != .running && self.tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if self.tool.name == "Task" && !self.tool.subagentTools.isEmpty {
                SubagentToolsList(tools: self.tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if self.showContent && self.tool.status != .running && self.tool.name != "Task" && (self.hasResult || self.tool.name == "Edit") {
                ToolResultContent(tool: self.tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if self.tool.name == "Edit" && self.tool.status == .running {
                EditInputDiffView(input: self.tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.canExpand && self.isHovering ? Color.white.opacity(0.05) : Color.clear),
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHovering = hovering
        }
        .onTapGesture {
            if self.canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: self.isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.isExpanded)
    }

    // MARK: Private

    @State private var pulseOpacity = 0.6
    @State private var isExpanded = false
    @State private var isHovering = false

    private var statusColor: Color {
        switch self.tool.status {
        case .running:
            Color.white
        case .waitingForApproval:
            Color.orange
        case .success:
            Color.green
        case .error,
             .interrupted:
            Color.red
        }
    }

    private var textColor: Color {
        switch self.tool.status {
        case .running:
            .white.opacity(0.6)
        case .waitingForApproval:
            Color.orange.opacity(0.9)
        case .success:
            .white.opacity(0.7)
        case .error,
             .interrupted:
            Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        self.tool.result != nil || self.tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        self.tool.name != "Task" && self.tool.name != "Edit" && self.hasResult
    }

    private var showContent: Bool {
        self.tool.name == "Edit" || self.isExpanded
    }

    private var agentDescription: String? {
        guard self.tool.name == "AgentOutputTool",
              let agentID = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionID]
        else {
            return nil
        }
        return sessionDescriptions[agentID]
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true),
        ) {
            self.pulseOpacity = 0.15
        }
    }
}

// MARK: - SubagentToolsList

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    // MARK: Internal

    let tools: [SubagentToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if self.hiddenCount > 0 {
                Text("+\(self.hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(self.recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }

    // MARK: Private

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, self.tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(self.tools.suffix(2))
    }
}

// MARK: - SubagentToolRow

/// Single subagent tool row
struct SubagentToolRow: View {
    // MARK: Internal

    let tool: SubagentToolCall

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(self.statusColor.opacity(self.tool.status == .running ? self.dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(self.tool.status) // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if self.tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            self.dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(self.tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(self.statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Private

    @State private var dotOpacity = 0.5

    private var statusColor: Color {
        switch self.tool.status {
        case .running,
             .waitingForApproval: .orange
        case .success: .green
        case .error,
             .interrupted: .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if self.tool.status == .interrupted {
            "Interrupted"
        } else if self.tool.status == .running {
            ToolStatusDisplay.running(for: self.tool.name, input: self.tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            ToolStatusDisplay.running(for: self.tool.name, input: self.tool.input).text
        }
    }
}

// MARK: - SubagentToolsSummary

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    // MARK: Internal

    let tools: [SubagentToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(self.tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(self.toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03)),
        )
    }

    // MARK: Private

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in self.tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }
}

// MARK: - ThinkingView

struct ThinkingView: View {
    // MARK: Internal

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(self.isExpanded ? self.text : String(self.text.prefix(80)) + (self.canExpand ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .italic()
                .lineLimit(self.isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if self.canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.5))
                    .rotationEffect(.degrees(self.isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if self.canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    // MARK: Private

    @State private var isExpanded = false

    private var canExpand: Bool {
        self.text.count > 80
    }
}

// MARK: - InterruptedMessageView

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - ChatInteractivePromptBar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    // MARK: Internal

    let isInTmux: Bool
    let onGoToTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text("Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(self.showContent ? 1 : 0)
            .offset(x: self.showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if self.isInTmux {
                    self.onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(self.isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(self.isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showButton ? 1 : 0)
            .scaleEffect(self.showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44) // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                self.showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                self.showButton = true
            }
        }
    }

    // MARK: Private

    @State private var showContent = false
    @State private var showButton = false
}

// MARK: - ChatApprovalBar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    // MARK: Internal

    let tool: String
    let toolInput: String?
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(self.tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(self.showContent ? 1 : 0)
            .offset(x: self.showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                self.onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showDenyButton ? 1 : 0)
            .scaleEffect(self.showDenyButton ? 1 : 0.8)

            // Allow button
            Button {
                self.onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.95))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showAllowButton ? 1 : 0)
            .scaleEffect(self.showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44) // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                self.showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                self.showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                self.showAllowButton = true
            }
        }
    }

    // MARK: Private

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false
}

// MARK: - NewMessagesIndicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    // MARK: Internal

    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(self.count == 1 ? "1 new message" : "\(self.count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4),
            )
            .scaleEffect(self.isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                self.isHovering = hovering
            }
        }
    }

    // MARK: Private

    @State private var isHovering = false
}
