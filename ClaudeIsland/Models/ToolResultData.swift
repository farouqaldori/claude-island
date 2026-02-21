//
//  ToolResultData.swift
//  ClaudeIsland
//
//  Structured models for all Claude Code tool results
//

import Foundation

// MARK: - ToolResultData

/// Structured tool result data - parsed from JSONL tool_result blocks
nonisolated enum ToolResultData: Equatable, Sendable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case askUserQuestion(AskUserQuestionResult)
    case bashOutput(BashOutputResult)
    case killShell(KillShellResult)
    case exitPlanMode(ExitPlanModeResult)
    case mcp(MCPResult)
    case generic(GenericResult)
}

// MARK: - ReadResult

nonisolated struct ReadResult: Equatable, Sendable {
    let filePath: String
    let content: String
    let numLines: Int
    let startLine: Int
    let totalLines: Int

    var filename: String {
        URL(fileURLWithPath: self.filePath).lastPathComponent
    }
}

// MARK: - EditResult

nonisolated struct EditResult: Equatable, Sendable {
    let filePath: String
    let oldString: String
    let newString: String
    let replaceAll: Bool
    let userModified: Bool
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: self.filePath).lastPathComponent
    }
}

// MARK: - PatchHunk

nonisolated struct PatchHunk: Equatable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

// MARK: - WriteResult

nonisolated struct WriteResult: Equatable, Sendable {
    enum WriteType: String, Equatable, Sendable {
        case create
        case overwrite
    }

    let type: WriteType
    let filePath: String
    let content: String
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: self.filePath).lastPathComponent
    }
}

// MARK: - BashResult

nonisolated struct BashResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let interrupted: Bool
    let isImage: Bool
    let returnCodeInterpretation: String?
    let backgroundTaskID: String?

    var hasOutput: Bool {
        !self.stdout.isEmpty || !self.stderr.isEmpty
    }

    var displayOutput: String {
        if !self.stdout.isEmpty {
            return self.stdout
        }
        if !self.stderr.isEmpty {
            return self.stderr
        }
        return "(No content)"
    }
}

// MARK: - GrepResult

nonisolated struct GrepResult: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case filesWithMatches = "files_with_matches"
        case content
        case count
    }

    let mode: Mode
    let filenames: [String]
    let numFiles: Int
    let content: String?
    let numLines: Int?
    let appliedLimit: Int?
}

// MARK: - GlobResult

nonisolated struct GlobResult: Equatable, Sendable {
    let filenames: [String]
    let durationMs: Int
    let numFiles: Int
    let truncated: Bool
}

// MARK: - TodoWriteResult

nonisolated struct TodoWriteResult: Equatable, Sendable {
    let oldTodos: [TodoItem]
    let newTodos: [TodoItem]
}

// MARK: - TodoItem

nonisolated struct TodoItem: Equatable, Sendable {
    let content: String
    let status: String // "pending", "in_progress", "completed"
    let activeForm: String?
}

// MARK: - TaskResult

nonisolated struct TaskResult: Equatable, Sendable {
    let agentID: String
    let status: String
    let content: String
    let prompt: String?
    let totalDurationMs: Int?
    let totalTokens: Int?
    let totalToolUseCount: Int?
}

// MARK: - WebFetchResult

nonisolated struct WebFetchResult: Equatable, Sendable {
    let url: String
    let code: Int
    let codeText: String
    let bytes: Int
    let durationMs: Int
    let result: String
}

// MARK: - WebSearchResult

nonisolated struct WebSearchResult: Equatable, Sendable {
    let query: String
    let durationSeconds: Double
    let results: [SearchResultItem]
}

// MARK: - SearchResultItem

nonisolated struct SearchResultItem: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

// MARK: - AskUserQuestionResult

nonisolated struct AskUserQuestionResult: Equatable, Sendable {
    let questions: [QuestionItem]
    let answers: [String: String]
}

// MARK: - QuestionItem

nonisolated struct QuestionItem: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [QuestionOption]
}

// MARK: - QuestionOption

nonisolated struct QuestionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

// MARK: - BashOutputResult

nonisolated struct BashOutputResult: Equatable, Sendable {
    let shellID: String
    let status: String
    let stdout: String
    let stderr: String
    let stdoutLines: Int
    let stderrLines: Int
    let exitCode: Int?
    let command: String?
    let timestamp: String?
}

// MARK: - KillShellResult

nonisolated struct KillShellResult: Equatable, Sendable {
    let shellID: String
    let message: String
}

// MARK: - ExitPlanModeResult

nonisolated struct ExitPlanModeResult: Equatable, Sendable {
    let filePath: String?
    let plan: String?
    let isAgent: Bool
}

// MARK: - MCPResult

nonisolated struct MCPResult: Equatable, Sendable {
    let serverName: String
    let toolName: String
    /// JSON-serialized result data for Sendable safety
    let rawResultJSON: String

    /// Deserialize the raw result for display purposes
    var rawResultEntries: [(key: String, value: String)] {
        guard let data = rawResultJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        return dict.map { (key: $0.key, value: String(describing: $0.value)) }
    }
}

// MARK: - GenericResult

nonisolated struct GenericResult: Equatable, Sendable {
    let rawContent: String?
}

// MARK: - ToolStatusDisplay

nonisolated struct ToolStatusDisplay {
    // MARK: Internal

    let text: String
    let isRunning: Bool

    /// Get running status text for a tool
    static func running(for toolName: String, input: [String: String]) -> Self {
        if let text = runningStatusText(for: toolName, input: input) {
            return Self(text: text, isRunning: true)
        }
        return Self(text: "Running...", isRunning: true)
    }

    /// Get completed status text for a tool result
    static func completed(for toolName: String, result: ToolResultData?) -> Self {
        guard let result else {
            return Self(text: "Completed", isRunning: false)
        }
        return Self(text: self.completedStatusText(for: result), isRunning: false)
    }

    // MARK: Private

    private static let simpleRunningStatus: [String: String] = [
        "Read": "Reading...",
        "Edit": "Editing...",
        "Write": "Writing...",
        "WebFetch": "Fetching...",
        "TodoWrite": "Updating todos...",
        "EnterPlanMode": "Entering plan mode...",
        "ExitPlanMode": "Exiting plan mode...",
    ]

    private static func runningStatusText(for toolName: String, input: [String: String]) -> String? {
        if let simple = simpleRunningStatus[toolName] {
            return simple
        }
        return self.inputBasedRunningStatus(for: toolName, input: input)
    }

    private static func inputBasedRunningStatus(for toolName: String, input: [String: String]) -> String? {
        switch toolName {
        case "Bash":
            input["description"].flatMap { $0.isEmpty ? nil : $0 }
        case "Grep",
             "Glob":
            input["pattern"].map { "Searching: \($0)" } ?? "Searching..."
        case "WebSearch":
            input["query"].map { "Searching: \($0)" } ?? "Searching..."
        case "Task":
            input["description"].flatMap { $0.isEmpty ? nil : $0 } ?? "Running agent..."
        default:
            nil
        }
    }

    private static func completedStatusText(for result: ToolResultData) -> String {
        switch result {
        case let .read(readRes):
            self.formatReadStatus(readRes)
        case let .edit(editRes):
            "Edited \(editRes.filename)"
        case let .write(writeRes):
            "\(writeRes.type == .create ? "Created" : "Wrote") \(writeRes.filename)"
        case let .bash(bashRes):
            self.formatBashStatus(bashRes)
        case let .grep(grepRes):
            self.formatCountStatus("Found", grepRes.numFiles, "file")
        case let .glob(globRes):
            globRes.numFiles == 0 ? "No files found" : self.formatCountStatus("Found", globRes.numFiles, "file")
        case .todoWrite:
            "Updated todos"
        case let .task(taskRes):
            taskRes.status.capitalized
        case let .webFetch(fetchRes):
            "\(fetchRes.code) \(fetchRes.codeText)"
        case let .webSearch(searchRes):
            self.formatSearchStatus(searchRes)
        case .askUserQuestion:
            "Answered"
        case let .bashOutput(outputRes):
            "Status: \(outputRes.status)"
        case .killShell:
            "Terminated"
        case .exitPlanMode:
            "Plan ready"
        case .mcp,
             .generic:
            "Completed"
        }
    }

    private static func formatReadStatus(_ result: ReadResult) -> String {
        let lineText = result.totalLines > result.numLines ? "\(result.numLines)+ lines" : "\(result.numLines) lines"
        return "Read \(result.filename) (\(lineText))"
    }

    private static func formatBashStatus(_ result: BashResult) -> String {
        if let bgID = result.backgroundTaskID { return "Running in background (\(bgID))" }
        if let interpretation = result.returnCodeInterpretation { return interpretation }
        return "Completed"
    }

    private static func formatCountStatus(_ prefix: String, _ count: Int, _ word: String) -> String {
        "\(prefix) \(count) \(count == 1 ? word : word + "s")"
    }

    private static func formatSearchStatus(_ result: WebSearchResult) -> String {
        let time = result.durationSeconds >= 1 ?
            "\(Int(result.durationSeconds))s" : "\(Int(result.durationSeconds * 1000))ms"
        let searchWord = result.results.count == 1 ? "search" : "searches"
        return "Did 1 \(searchWord) in \(time)"
    }
}
