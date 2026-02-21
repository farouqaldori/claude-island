//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

// swiftlint:disable file_length

import Foundation
import os.log

// Central state manager for all Claude sessions
// Uses Swift actor for thread-safe state mutations
// swiftlint:disable:next type_body_length
actor SessionStore {
    // MARK: Lifecycle

    // MARK: - Initialization

    private init() {}

    // MARK: Internal

    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionID
    ///
    /// **IMPORTANT:** Do not access directly from outside SessionStore.
    /// All state mutations must flow through `process(_ event:)` to maintain
    /// the event-driven state machine. Internal visibility is required for
    /// SessionStore extensions (e.g., SessionStore+Subagents.swift).
    /// Use `session(for:)` or `allSessions()` for read-only access.
    var sessions: [String: SessionState] = [:]

    // MARK: - Periodic Status Check (see SessionStore+PeriodicCheck.swift)

    var statusCheckTask: Task<Void, Never>?
    let statusCheckInterval: Duration = .seconds(3)

    /// Create a new stream of session state changes.
    /// Yields the current sessions immediately, then yields on every subsequent state change.
    /// Multiple subscribers are supported — each call returns an independent stream.
    nonisolated func sessionsStream() -> AsyncStream<[SessionState]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [SessionState].self, bufferingPolicy: .bufferingNewest(1))
        // Set onTermination synchronously (before any Task) to avoid a race where
        // the stream terminates before registerContinuation installs the handler.
        continuation.onTermination = { [weak self] _ in
            Task(name: "session-stream-deregister") { await self?.removeContinuation(id: id) }
        }
        Task(name: "session-stream-register") {
            await self.registerContinuation(continuation, id: id)
        }
        return stream
    }

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async { // swiftlint:disable:this cyclomatic_complexity
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        // Record to audit trail
        self.recordAuditEntry(event: event)

        switch event {
        case let .hookReceived(hookEvent):
            await self.processHookEvent(hookEvent)

        case let .permissionApproved(sessionID, toolUseID):
            await self.processPermissionApproved(sessionID: sessionID, toolUseID: toolUseID)

        case let .permissionDenied(sessionID, toolUseID, reason):
            await self.processPermissionDenied(sessionID: sessionID, toolUseID: toolUseID, reason: reason)

        case let .permissionSocketFailed(sessionID, toolUseID):
            await self.processSocketFailure(sessionID: sessionID, toolUseID: toolUseID)

        case let .fileUpdated(payload):
            await self.processFileUpdate(payload)

        case let .interruptDetected(sessionID):
            await self.processInterrupt(sessionID: sessionID)

        case let .clearDetected(sessionID):
            await self.processClearDetected(sessionID: sessionID)

        case let .sessionEnded(sessionID):
            await self.processSessionEnd(sessionID: sessionID)

        case let .loadHistory(sessionID, cwd):
            await self.loadHistoryFromFile(sessionID: sessionID, cwd: cwd)

        case let .historyLoaded(payload):
            await self.processHistoryLoaded(payload)

        case let .toolCompleted(sessionID, toolUseID, result):
            await self.processToolCompleted(sessionID: sessionID, toolUseID: toolUseID, result: result)

        // MARK: - Subagent Events

        case let .subagentStarted(sessionID, taskToolID):
            handleSubagentStarted(sessionID: sessionID, taskToolID: taskToolID)

        case let .subagentToolExecuted(sessionID, tool):
            handleSubagentToolExecuted(sessionID: sessionID, tool: tool)

        case let .subagentToolCompleted(sessionID, toolID, status):
            handleSubagentToolCompleted(sessionID: sessionID, toolID: toolID, status: status)

        case let .subagentStopped(sessionID, taskToolID):
            handleSubagentStopped(sessionID: sessionID, taskToolID: taskToolID)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        self.publishState()
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionID: String) -> SessionState? {
        self.sessions[sessionID]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionID: String) -> Bool {
        guard let session = sessions[sessionID] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(self.sessions.values)
    }

    /// Get recent events for debugging (most recent first)
    func recentEvents(limit: Int = 20) -> [(timestamp: Date, event: String, sessionID: String?)] {
        self.eventAuditTrail.suffix(limit).reversed().map {
            (timestamp: $0.timestamp, event: $0.event, sessionID: $0.sessionID)
        }
    }

    // MARK: - File Sync Scheduling

    func scheduleFileSync(sessionID: String, cwd: String) {
        // Cancel existing sync
        self.cancelPendingSync(sessionID: sessionID)

        // Schedule new debounced sync
        // Note: Actors maintain strong references during execution, so [weak self] is unnecessary
        self.pendingSyncs[sessionID] = Task(name: "file-sync") {
            try? await Task.sleep(for: self.syncDebounce)
            guard !Task.isCancelled else { return }

            // Revalidate session still exists after sleep (actor reentrancy protection)
            guard self.sessions[sessionID] != nil else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionID: sessionID,
                cwd: cwd,
            )

            // Recheck cancellation after await
            guard !Task.isCancelled else { return }

            if result.clearDetected {
                await self.process(.clearDetected(sessionID: sessionID))
                // Recheck cancellation after clear processing
                guard !Task.isCancelled else { return }
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            // Revalidate session still exists before processing file update
            guard self.sessions[sessionID] != nil else { return }

            let payload = FileUpdatePayload(
                sessionID: sessionID,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIDs: result.completedToolIDs,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults,
            )

            await self.process(.fileUpdated(payload))
        }
    }

    // MARK: Private

    /// An entry in the event audit trail
    private struct AuditEntry {
        let timestamp: Date
        let event: String
        let sessionID: String?
    }

    /// Registry of continuations for multi-subscriber AsyncStream support
    private var sessionsContinuations: [UUID: AsyncStream<[SessionState]>.Continuation] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounce: Duration = .milliseconds(100)

    // MARK: - Event Audit Trail

    /// Ring buffer of recent events for debugging
    private var eventAuditTrail: [AuditEntry] = []
    private let maxAuditEntries = 100

    /// Register a continuation and yield the current state.
    /// The `id` and `onTermination` are set by `sessionsStream()` before calling this method
    /// to avoid a race between stream termination and registration.
    private func registerContinuation(_ continuation: AsyncStream<[SessionState]>.Continuation, id: UUID) {
        self.sessionsContinuations[id] = continuation
        // Yield current state immediately (replaces CurrentValueSubject's initial value behavior)
        let currentSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        continuation.yield(currentSessions)
    }

    /// Remove a continuation when the stream terminates
    private func removeContinuation(id: UUID) {
        self.sessionsContinuations.removeValue(forKey: id)
    }

    // MARK: - Published State (for UI)

    /// Record an event to the audit trail
    private func recordAuditEntry(event: SessionEvent) {
        let entry = AuditEntry(
            timestamp: Date(),
            event: String(describing: event).prefix(200).description,
            sessionID: event.sessionID,
        )

        self.eventAuditTrail.append(entry)

        // Trim if over limit (ring buffer)
        if self.eventAuditTrail.count > self.maxAuditEntries {
            self.eventAuditTrail.removeFirst(self.eventAuditTrail.count - self.maxAuditEntries)
        }
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionID = event.sessionID
        var session = self.sessions[sessionID] ?? self.createSession(from: event)

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            self.sessions.removeValue(forKey: sessionID)
            self.cancelPendingSync(sessionID: sessionID)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger
                .debug(
                    "Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring",
                )
        }

        if event.event == "PermissionRequest", let toolUseID = event.toolUseID {
            Self.logger.debug("Setting tool \(toolUseID.prefix(12), privacy: .public) status to waitingForApproval")
            self.updateToolStatus(in: &session, toolID: toolUseID, status: .waitingForApproval)
        }

        self.processToolTracking(event: event, session: &session)
        trackSubagent(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        self.sessions[sessionID] = session
        self.publishState()

        if event.shouldSyncFile {
            self.scheduleFileSync(sessionID: sessionID, cwd: event.cwd)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionID: event.sessionID,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false, // Will be updated
            phase: .idle,
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseID = event.toolUseID, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseID, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseID }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.stringValue {
                                input[key] = str
                            } else if let num = value.intValue {
                                input[key] = String(num)
                            } else if let bool = value.boolValue {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseID,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: [],
                        )),
                        timestamp: Date(),
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseID.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseID = event.toolUseID {
                session.toolTracker.completeTool(id: toolUseID, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0 ..< session.chatItems.count {
                    if session.chatItems[i].id == toolUseID,
                       case var .toolCall(tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseID,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp,
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionID: String, toolUseID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Update tool status in chat history first
        self.updateToolStatus(in: &session, toolID: toolUseID, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil, // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp,
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        self.sessions[sessionID] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionID: String, toolUseID: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionID] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseID }),
           case let .toolCall(tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == toolUseID,
               case var .toolCall(tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp,
                )
                Self.logger
                    .debug(
                        "Tool \(toolUseID.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)",
                    )
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseID: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp,
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        self.sessions[sessionID] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolID: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolID { continue }
            if case let .toolCall(tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionID: String, toolUseID: String, reason: String?) async {
        guard var session = sessions[sessionID] else { return }

        // Update tool status in chat history first
        self.updateToolStatus(in: &session, toolID: toolUseID, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp,
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        self.sessions[sessionID] = session
    }

    private func processSocketFailure(sessionID: String, toolUseID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Mark the failed tool's status as error
        self.updateToolStatus(in: &session, toolID: toolUseID, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseID) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseID: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp,
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case let .waitingForApproval(ctx) = session.phase, ctx.toolUseID == toolUseID {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        self.sessions[sessionID] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionID] else { return }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionID: payload.sessionID,
            cwd: session.cwd,
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIDs = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case let .toolUse(tool):
                        validIDs.insert(tool.id)
                    case .text,
                         .thinking,
                         .interrupted:
                        let itemID = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIDs.insert(itemID)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIDs.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        self.processMessages(
            from: payload,
            into: &session,
        )

        if !payload.isIncremental {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await self.populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults,
        )

        self.sessions[payload.sessionID] = session

        await self.emitToolCompletionEvents(
            sessionID: payload.sessionID,
            session: session,
            completedToolIDs: payload.completedToolIDs,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
        )
    }

    /// Process messages from payload into session chat items
    private func processMessages(
        from payload: FileUpdatePayload,
        into session: inout SessionState,
    ) {
        var context = ItemCreationContext(
            existingIDs: Set(session.chatItems.map(\.id)),
            completedTools: payload.completedToolIDs,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
            toolTracker: session.toolTracker,
        )

        for message in payload.messages {
            for (blockIndex, block) in message.content.enumerated() {
                if case let .toolUse(tool) = block {
                    if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                        if case let .toolCall(existingTool) = session.chatItems[idx].type {
                            session.chatItems[idx] = ChatHistoryItem(
                                id: tool.id,
                                type: .toolCall(ToolCallItem(
                                    name: tool.name,
                                    input: tool.input,
                                    status: existingTool.status,
                                    result: existingTool.result,
                                    structuredResult: existingTool.structuredResult,
                                    subagentTools: existingTool.subagentTools,
                                )),
                                timestamp: message.timestamp,
                            )
                        }
                        continue
                    }
                }

                if let item = ChatItemFactory.createItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    context: &context,
                ) {
                    session.chatItems.append(item)
                }
            }
        }

        session.toolTracker = context.toolTracker
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData],
    ) async {
        for i in 0 ..< session.chatItems.count {
            guard case var .toolCall(tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case let .task(taskResult) = structuredResult,
                  !taskResult.agentID.isEmpty
            else { continue }

            let taskToolID = session.chatItems[i].id

            // Store agentID → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolID]?.description {
                session.subagentState.agentDescriptions[taskResult.agentID] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentID] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentID: taskResult.agentID,
                cwd: cwd,
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: self.parseTimestamp(info.timestamp) ?? Date(),
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolID,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp,
            )

            Self.logger
                .debug(
                    "Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolID.prefix(12), privacy: .public) from agent \(taskResult.agentID.prefix(8), privacy: .public)",
                )
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionID: String,
        session: SessionState,
        completedToolIDs: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
    ) async {
        for item in session.chatItems {
            guard case let .toolCall(tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIDs.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id],
            )

            // Process the completion event (this will update state and phase consistently)
            await self.process(.toolCompleted(sessionID: sessionID, toolUseID: item.id, result: result))
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolID: String, status: ToolStatus) {
        var found = false
        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == toolID,
               case var .toolCall(tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp,
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolID.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionID: String) async {
        guard var session = sessions[sessionID] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0 ..< session.chatItems.count {
            if case var .toolCall(tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp,
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        self.sessions[sessionID] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionID: String) async {
        guard var session = sessions[sessionID] else { return }

        Self.logger.info("Processing /clear for session \(sessionID.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        self.sessions[sessionID] = session

        Self.logger.info("/clear processed for session \(sessionID.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionID: String) async {
        self.sessions.removeValue(forKey: sessionID)
        self.cancelPendingSync(sessionID: sessionID)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionID: String, cwd: String) async {
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionID: sessionID,
            cwd: cwd,
        )
        let completedTools = await ConversationParser.shared.completedToolIDs(for: sessionID)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionID)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionID)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionID: sessionID,
            cwd: cwd,
        )

        // Process loaded history
        await self.process(.historyLoaded(HistoryLoadedPayload(
            sessionID: sessionID,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo,
        )))
    }

    private func processHistoryLoaded(_ payload: HistoryLoadedPayload) async {
        guard var session = sessions[payload.sessionID] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = payload.conversationInfo

        // Infer phase from conversation state when loading history
        // If Claude was the last to respond, the session is waiting for user input
        if session.phase == .idle {
            if let lastRole = payload.conversationInfo.lastMessageRole,
               lastRole == "assistant" || lastRole == "tool" {
                session.phase = .waitingForInput
                Self.logger.debug(
                    "History loaded: inferred phase .waitingForInput from lastMessageRole=\(lastRole, privacy: .public)",
                )
            }
        }

        // Convert messages to chat items
        var context = ItemCreationContext(
            existingIDs: Set(session.chatItems.map(\.id)),
            completedTools: payload.completedTools,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
            toolTracker: session.toolTracker,
        )

        for message in payload.messages {
            for (blockIndex, block) in message.content.enumerated() {
                if let item = ChatItemFactory.createItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    context: &context,
                ) {
                    session.chatItems.append(item)
                }
            }
        }

        session.toolTracker = context.toolTracker

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        self.sessions[payload.sessionID] = session
    }

    private func cancelPendingSync(sessionID: String) {
        self.pendingSyncs[sessionID]?.cancel()
        self.pendingSyncs.removeValue(forKey: sessionID)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        for (_, continuation) in self.sessionsContinuations {
            continuation.yield(sortedSessions)
        }
    }
}
