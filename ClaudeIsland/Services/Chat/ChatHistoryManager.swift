//
//  ChatHistoryManager.swift
//  ClaudeIsland
//

import Combine
import Foundation

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    /// Sessions whose JSONL file we've asked SessionStore to parse in this
    /// app session. Only populated by `loadFromFile` — NOT by session
    /// discovery via hooks. (Hook events only give tool calls, not the
    /// full user/assistant text conversation.)
    private var jsonlParsedSessions: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func history(for sessionId: String) -> [ChatHistoryItem] {
        histories[sessionId] ?? []
    }

    /// Whether we've parsed the session's JSONL file in this app session.
    /// Hook-driven session discovery does NOT mark a session as loaded —
    /// only an explicit `loadFromFile` call does.
    func isLoaded(sessionId: String) -> Bool {
        jsonlParsedSessions.contains(sessionId)
    }

    func loadFromFile(sessionId: String, cwd: String) async {
        guard !jsonlParsedSessions.contains(sessionId) else { return }
        jsonlParsedSessions.insert(sessionId)
        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
    }

    func syncFromFile(sessionId: String, cwd: String) async {
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
            isIncremental: false,  // Full sync
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for sessionId: String) {
        jsonlParsedSessions.remove(sessionId)
        histories.removeValue(forKey: sessionId)
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]
        var newAgentDescriptions: [String: [String: String]] = [:]
        for session in sessions {
            let filteredItems = filterOutSubagentTools(session.chatItems)
            newHistories[session.sessionId] = filteredItems
            newAgentDescriptions[session.sessionId] = session.subagentState.agentDescriptions
        }
        histories = newHistories
        agentDescriptions = newAgentDescriptions
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.isSubagentContainer {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIds.contains($0.id) }
    }
}

// MARK: - Models

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
    case image(ImageBlock)
    case interrupted
}

struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?

    /// AskUserQuestion: options sent from the notch, one line per question
    var answeredPicks: String = ""
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Whether this tool is the subagent-container tool. "Task" is the
    /// legacy name; Claude Code now uses "Agent".
    var isSubagentContainer: Bool {
        Self.isSubagentContainerName(name)
    }

    /// Same check by raw tool-name string (used when we don't have a
    /// ToolCallItem — e.g. when matching against `HookEvent.tool`).
    static func isSubagentContainerName(_ name: String?) -> Bool {
        name == "Task" || name == "Agent"
    }

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
        if let agentId = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentId.prefix(8))..."
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
        lhs.answeredPicks == rhs.answeredPicks &&
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
