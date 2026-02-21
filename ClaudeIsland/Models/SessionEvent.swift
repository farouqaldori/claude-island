//
//  SessionEvent.swift
//  ClaudeIsland
//
//  Unified event types for the session state machine.
//  All state changes flow through SessionStore.process(event).
//

import Foundation

// MARK: - SessionEvent

/// All events that can affect session state
/// This is the single entry point for state mutations
nonisolated enum SessionEvent: Sendable {
    // MARK: - Hook Events (from HookSocketServer)

    /// A hook event was received from Claude Code
    case hookReceived(HookEvent)

    // MARK: - Permission Events (user actions)

    /// User approved a permission request
    case permissionApproved(sessionID: String, toolUseID: String)

    /// User denied a permission request
    case permissionDenied(sessionID: String, toolUseID: String, reason: String?)

    /// Permission socket failed (connection died before response)
    case permissionSocketFailed(sessionID: String, toolUseID: String)

    // MARK: - File Events (from ConversationParser)

    /// JSONL file was updated with new content
    case fileUpdated(FileUpdatePayload)

    // MARK: - Tool Completion Events (from JSONL parsing)

    /// A tool was detected as completed via JSONL result
    /// This is the authoritative signal that a tool has finished
    case toolCompleted(sessionID: String, toolUseID: String, result: ToolCompletionResult)

    // MARK: - Interrupt Events (from JSONLInterruptWatcher)

    /// User interrupted Claude (detected via JSONL)
    case interruptDetected(sessionID: String)

    // MARK: - Subagent Events (Task tool tracking)

    /// A Task (subagent) tool has started
    case subagentStarted(sessionID: String, taskToolID: String)

    /// A tool was executed within an active subagent
    case subagentToolExecuted(sessionID: String, tool: SubagentToolCall)

    /// A subagent tool completed (status update)
    case subagentToolCompleted(sessionID: String, toolID: String, status: ToolStatus)

    /// A Task (subagent) tool has stopped
    case subagentStopped(sessionID: String, taskToolID: String)

    /// Agent file was updated with new subagent tools (from AgentFileWatcher)
    case agentFileUpdated(sessionID: String, taskToolID: String, tools: [SubagentToolInfo])

    // MARK: - Clear Events (from JSONL detection)

    /// User issued /clear command - reset UI state while keeping session alive
    case clearDetected(sessionID: String)

    // MARK: - Session Lifecycle

    /// Session has ended
    case sessionEnded(sessionID: String)

    /// Request to load initial history from file
    case loadHistory(sessionID: String, cwd: String)

    /// History load completed
    case historyLoaded(HistoryLoadedPayload)
}

// MARK: - HistoryLoadedPayload

/// Payload for history loaded events
nonisolated struct HistoryLoadedPayload: Sendable {
    let sessionID: String
    let messages: [ChatMessage]
    let completedTools: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    let conversationInfo: ConversationInfo
}

// MARK: - FileUpdatePayload

/// Payload for file update events
nonisolated struct FileUpdatePayload: Sendable {
    let sessionID: String
    let cwd: String
    /// Messages to process - either only new messages (if isIncremental) or all messages
    let messages: [ChatMessage]
    /// When true, messages contains only NEW messages since last update
    /// When false, messages contains ALL messages (used for initial load or after /clear)
    let isIncremental: Bool
    let completedToolIDs: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
}

// MARK: - ToolCompletionResult

/// Result of a tool completion detected from JSONL
nonisolated struct ToolCompletionResult: Sendable {
    let status: ToolStatus
    let result: String?
    let structuredResult: ToolResultData?

    nonisolated static func from(parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) -> Self {
        let status: ToolStatus = if parserResult?.isInterrupted == true {
            .interrupted
        } else if parserResult?.isError == true {
            .error
        } else {
            .success
        }

        var resultText: String?
        if let parsedResult = parserResult {
            if !parsedResult.isInterrupted {
                if let stdout = parsedResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parsedResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parsedResult.content, !content.isEmpty {
                    resultText = content
                }
            }
        }

        return Self(status: status, result: resultText, structuredResult: structuredResult)
    }
}

// MARK: - Hook Event Extensions

nonisolated extension HookEvent {
    /// Determine the target session phase based on this hook event
    nonisolated func determinePhase() -> SessionPhase {
        // PreCompact takes priority
        if event == "PreCompact" {
            return .compacting
        }

        // Permission request creates waitingForApproval state
        if expectsResponse, let tool {
            return .waitingForApproval(PermissionContext(
                toolUseID: toolUseID ?? "",
                toolName: tool,
                toolInput: toolInput,
                receivedAt: Date(),
            ))
        }

        // Handle Notification events explicitly
        if event == "Notification" {
            if notificationType == "idle_prompt" {
                // idle_prompt means Claude finished and is waiting for user input
                return .waitingForInput
            }
            // Other notifications - session is still processing
            return .processing
        }

        switch status {
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool",
             "processing",
             "starting":
            return .processing
        case "notification":
            // Explicit notification status - session is still active
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            // Unknown status - default to idle
            return .idle
        }
    }

    /// Whether this is a tool-related event
    nonisolated var isToolEvent: Bool {
        event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest"
    }

    /// Whether this event should trigger a file sync
    nonisolated var shouldSyncFile: Bool {
        switch event {
        case "UserPromptSubmit",
             "PreToolUse",
             "PostToolUse",
             "Stop":
            true
        default:
            false
        }
    }
}

// MARK: - SessionEvent + sessionID

nonisolated extension SessionEvent {
    /// Extract the session ID from this event (if available)
    nonisolated var sessionID: String? {
        switch self {
        case let .hookReceived(event):
            event.sessionID
        case let .permissionApproved(sessionID, _),
             let .permissionDenied(sessionID, _, _),
             let .permissionSocketFailed(sessionID, _),
             let .interruptDetected(sessionID),
             let .clearDetected(sessionID),
             let .sessionEnded(sessionID),
             let .loadHistory(sessionID, _),
             let .toolCompleted(sessionID, _, _),
             let .subagentStarted(sessionID, _),
             let .subagentToolExecuted(sessionID, _),
             let .subagentToolCompleted(sessionID, _, _),
             let .subagentStopped(sessionID, _),
             let .agentFileUpdated(sessionID, _, _):
            sessionID
        case let .fileUpdated(payload):
            payload.sessionID
        case let .historyLoaded(payload):
            payload.sessionID
        }
    }
}

// MARK: - SessionEvent + CustomStringConvertible

nonisolated extension SessionEvent: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case let .hookReceived(event):
            "hookReceived(\(event.event), session: \(event.sessionID.prefix(8)))"
        case let .permissionApproved(sessionID, toolUseID):
            "permissionApproved(session: \(sessionID.prefix(8)), tool: \(toolUseID.prefix(12)))"
        case let .permissionDenied(sessionID, toolUseID, _):
            "permissionDenied(session: \(sessionID.prefix(8)), tool: \(toolUseID.prefix(12)))"
        case let .permissionSocketFailed(sessionID, toolUseID):
            "permissionSocketFailed(session: \(sessionID.prefix(8)), tool: \(toolUseID.prefix(12)))"
        case let .fileUpdated(payload):
            "fileUpdated(session: \(payload.sessionID.prefix(8)), messages: \(payload.messages.count))"
        case let .interruptDetected(sessionID):
            "interruptDetected(session: \(sessionID.prefix(8)))"
        case let .clearDetected(sessionID):
            "clearDetected(session: \(sessionID.prefix(8)))"
        case let .sessionEnded(sessionID):
            "sessionEnded(session: \(sessionID.prefix(8)))"
        case let .loadHistory(sessionID, _):
            "loadHistory(session: \(sessionID.prefix(8)))"
        case let .historyLoaded(payload):
            "historyLoaded(session: \(payload.sessionID.prefix(8)), messages: \(payload.messages.count))"
        case let .toolCompleted(sessionID, toolUseID, result):
            "toolCompleted(session: \(sessionID.prefix(8)), tool: \(toolUseID.prefix(12)), status: \(result.status))"
        case let .subagentStarted(sessionID, taskToolID):
            "subagentStarted(session: \(sessionID.prefix(8)), task: \(taskToolID.prefix(12)))"
        case let .subagentToolExecuted(sessionID, tool):
            "subagentToolExecuted(session: \(sessionID.prefix(8)), tool: \(tool.name))"
        case let .subagentToolCompleted(sessionID, toolID, status):
            "subagentToolCompleted(session: \(sessionID.prefix(8)), tool: \(toolID.prefix(12)), status: \(status))"
        case let .subagentStopped(sessionID, taskToolID):
            "subagentStopped(session: \(sessionID.prefix(8)), task: \(taskToolID.prefix(12)))"
        case let .agentFileUpdated(sessionID, taskToolID, tools):
            "agentFileUpdated(session: \(sessionID.prefix(8)), task: \(taskToolID.prefix(12)), tools: \(tools.count))"
        }
    }
}
