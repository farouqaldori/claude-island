//
//  ChatHistoryManager.swift
//  ClaudeIsland
//

import Foundation
import Observation

// MARK: - ChatHistoryManager

/// Manager for chat history using modern @Observable macro for efficient SwiftUI updates.
/// Subscribes to SessionStore's Combine publisher to receive session state changes.
@Observable
final class ChatHistoryManager {
    // MARK: Lifecycle

    private init() {
        self.sessionsTask = Task(name: "chat-history-stream") { [weak self] in
            let stream = SessionStore.shared.sessionsStream()
            for await sessions in stream {
                self?.updateFromSessions(sessions)
            }
        }
    }

    // MARK: Internal

    static let shared = ChatHistoryManager()

    private(set) var histories: [String: [ChatHistoryItem]] = [:]
    private(set) var agentDescriptions: [String: [String: String]] = [:]

    // MARK: - Public API

    func history(for sessionID: String) -> [ChatHistoryItem] {
        self.histories[sessionID] ?? []
    }

    func isLoaded(sessionID: String) -> Bool {
        self.loadedSessions.contains(sessionID)
    }

    func loadFromFile(sessionID: String, cwd: String) async {
        guard !self.loadedSessions.contains(sessionID) else { return }
        self.loadedSessions.insert(sessionID)
        await SessionStore.shared.process(.loadHistory(sessionID: sessionID, cwd: cwd))
    }

    func syncFromFile(sessionID: String, cwd: String) async {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionID: sessionID,
            cwd: cwd,
        )
        let completedTools = await ConversationParser.shared.completedToolIDs(for: sessionID)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionID)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionID)

        let payload = FileUpdatePayload(
            sessionID: sessionID,
            cwd: cwd,
            messages: messages,
            isIncremental: false, // Full sync
            completedToolIDs: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for sessionID: String) {
        self.loadedSessions.remove(sessionID)
        self.histories.removeValue(forKey: sessionID)
        Task(name: "clear-history") {
            await SessionStore.shared.process(.sessionEnded(sessionID: sessionID))
        }
    }

    // MARK: Private

    /// Tracks which sessions have been loaded - ignored by Observation since it's internal state
    @ObservationIgnored private var loadedSessions: Set<String> = []
    /// Task for sessions stream subscription
    @ObservationIgnored private var sessionsTask: Task<Void, Never>?

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]
        var newAgentDescriptions: [String: [String: String]] = [:]
        for session in sessions {
            let filteredItems = self.filterOutSubagentTools(session.chatItems)
            newHistories[session.sessionID] = filteredItems
            newAgentDescriptions[session.sessionID] = session.subagentState.agentDescriptions
            self.loadedSessions.insert(session.sessionID)
        }
        self.histories = newHistories
        self.agentDescriptions = newAgentDescriptions
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIDs = Set<String>()
        for item in items {
            if case let .toolCall(tool) = item.type, tool.name == "Task" {
                for subagentTool in tool.subagentTools {
                    subagentToolIDs.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIDs.contains($0.id) }
    }
}

// MARK: - ChatHistoryItem

nonisolated struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

// MARK: - ChatHistoryItemType

nonisolated enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
}

// MARK: - ToolCallItem

nonisolated struct ToolCallItem: Equatable, Sendable {
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
        if let agentID = input["agentId"] {
            let blocking = self.input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentID.prefix(8))..."
        }
        return self.input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if self.status == .running {
            return ToolStatusDisplay.running(for: self.name, input: self.input)
        }
        if self.status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if self.status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: self.name, result: self.structuredResult)
    }
}

// MARK: - ToolStatus

nonisolated enum ToolStatus: Equatable, Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    // MARK: Internal

    nonisolated var description: String {
        switch self {
        case .running: "running"
        case .waitingForApproval: "waitingForApproval"
        case .success: "success"
        case .error: "error"
        case .interrupted: "interrupted"
        }
    }
}

// MARK: - SubagentToolCall

/// Represents a tool call made by a subagent (Task tool)
nonisolated struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch self.name {
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
            return self.name
        }
    }
}
