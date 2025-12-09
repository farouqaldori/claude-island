//
//  ChatHistoryManager.swift
//  ClaudeIsland
//
//  Read-only accessor for chat history.
//  All state is owned by SessionStore - this provides backward compatibility for UI.
//

import Combine
import Foundation

/// Read-only accessor for chat history
/// State is owned by SessionStore - this class provides backward compatibility for existing UI
@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    /// Published history per session (read from SessionStore)
    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]

    /// Track which sessions have been loaded
    private var loadedSessions: Set<String> = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Subscribe to SessionStore and extract chat items
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Get history for a session
    func history(for sessionId: String) -> [ChatHistoryItem] {
        histories[sessionId] ?? []
    }

    /// Check if session history has been loaded
    func isLoaded(sessionId: String) -> Bool {
        loadedSessions.contains(sessionId)
    }

    /// Load initial history from conversation file
    func loadFromFile(sessionId: String, cwd: String) async {
        guard !loadedSessions.contains(sessionId) else { return }
        loadedSessions.insert(sessionId)

        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }

    /// Sync history from JSONL file (triggers file update)
    func syncFromFile(sessionId: String, cwd: String) async {
        // Parse and send to SessionStore
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        let payload = FileUpdatePayload(
            sessionId: sessionId,
            cwd: cwd,
            messages: messages,
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    /// Clear history for a session
    func clearHistory(for sessionId: String) {
        loadedSessions.remove(sessionId)
        histories.removeValue(forKey: sessionId)
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]
        for session in sessions {
            // Log Task tools with subagent tools for debugging
            for item in session.chatItems {
                if case .toolCall(let tool) = item.type, tool.name == "Task" {
                    print("ChatHistoryManager: Task \(item.id.prefix(12)) has \(tool.subagentTools.count) subagent tools")
                }
            }

            // Filter out subagent tools - they should only appear nested under their Task
            let filteredItems = filterOutSubagentTools(session.chatItems)
            newHistories[session.sessionId] = filteredItems
            loadedSessions.insert(session.sessionId)
        }
        histories = newHistories
    }

    /// Filter out tools that are nested under a Task (subagent tools)
    /// These tools should only be shown nested, not at the top level
    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        // Collect all subagent tool IDs from Task tools
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.name == "Task" {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }

        // Filter out items whose ID is in subagentToolIds
        return items.filter { item in
            !subagentToolIds.contains(item.id)
        }
    }

    // MARK: - Legacy Compatibility Methods (No-ops or delegates to SessionStore)

    /// Mark a tool as waiting for approval (now handled by SessionStore)
    func markToolWaitingForApproval(sessionId: String, toolId: String) {
        // No-op - SessionStore handles this via phase transitions
    }

    /// Mark a tool as approved (now handled by SessionStore)
    func markToolApproved(sessionId: String, toolId: String) {
        // No-op - SessionStore handles this via permission events
    }

    /// Mark a tool as denied (now handled by SessionStore)
    func markToolDenied(sessionId: String, toolId: String) {
        // No-op - SessionStore handles this via permission events
    }

    /// Check if session has active subagent (delegates to SessionStore)
    func hasActiveSubagent(sessionId: String) -> Bool {
        guard let session = histories[sessionId] else { return false }
        // Check if any Task tool is running
        return session.contains { item in
            if case .toolCall(let tool) = item.type {
                return tool.name == "Task" && tool.status == .running
            }
            return false
        }
    }

    /// Mark pending Task tool (now tracked by SessionStore)
    func markPendingTaskTool(sessionId: String) {
        // No-op - SessionStore handles subagent state
    }

    /// Stop subagent tracking (now handled by SessionStore)
    func stopSubagentTracking(sessionId: String) {
        // No-op - SessionStore handles this on Stop events
    }

    /// Stop most recent Task (now handled by SessionStore)
    func stopMostRecentTask(sessionId: String, success: Bool) {
        // No-op - SessionStore handles this on PostToolUse
    }

    /// Mark subagent tool completed (now handled by SessionStore)
    func markSubagentToolCompleted(sessionId: String, toolId: String, success: Bool) {
        // No-op - SessionStore handles this via file sync
    }
}

// MARK: - Models (kept for backward compatibility)

struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
}

struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    // Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

// Explicit nonisolated Equatable conformance to avoid actor isolation issues
extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): return true
        case (.waitingForApproval, .waitingForApproval): return true
        case (.success, .success): return true
        case (.error, .error): return true
        case (.interrupted, .interrupted): return true
        default: return false
        }
    }
}

// MARK: - Subagent Tool Call

/// Represents a tool call made by a subagent (Task tool)
struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Reading..."
        case "Grep":
            if let pattern = input["pattern"] {
                return "grep: \(pattern)"
            }
            return "Searching..."
        case "Glob":
            if let pattern = input["pattern"] {
                return "glob: \(pattern)"
            }
            return "Finding files..."
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return "Running command..."
        case "Edit":
            if let path = input["file_path"] {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Editing..."
        case "Write":
            if let path = input["file_path"] {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Writing..."
        case "WebFetch":
            if let url = input["url"] {
                return "Fetching: \(url.prefix(30))..."
            }
            return "Fetching..."
        case "WebSearch":
            if let query = input["query"] {
                return "Search: \(query.prefix(30))"
            }
            return "Searching web..."
        default:
            return name
        }
    }
}
