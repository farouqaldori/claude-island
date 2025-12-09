//
//  MCPToolFormatter.swift
//  ClaudeIsland
//
//  Utility for formatting MCP tool names and arguments
//

import Foundation

struct MCPToolFormatter {

    /// Tool aliases for friendlier display names
    private static let toolAliases: [String: String] = [
        "AskUserQuestion": "Question",
        "TodoWrite": "Todo",
        "TodoRead": "Todo",
        "WebFetch": "Fetch",
        "WebSearch": "Search",
        "NotebookEdit": "Notebook",
        "BashOutput": "Bash",
        "KillShell": "Shell",
        "EnterPlanMode": "Plan",
        "ExitPlanMode": "Plan",
        "SlashCommand": "Command",
    ]

    /// Checks if tool name is in MCP format (e.g., "mcp__deepwiki__ask_question")
    static func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    /// Converts snake_case to Title Case
    /// e.g., "ask_question" → "Ask Question"
    static func toTitleCase(_ snakeCase: String) -> String {
        snakeCase
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Formats MCP tool ID to human-readable format
    /// e.g., "mcp__deepwiki__ask_question" → "Deepwiki - Ask Question"
    /// Returns alias if available, otherwise original name
    static func formatToolName(_ toolId: String) -> String {
        // Check for alias first
        if let alias = toolAliases[toolId] {
            return alias
        }

        guard isMCPTool(toolId) else { return toolId }

        // Remove "mcp__" prefix and split by "__"
        let withoutPrefix = String(toolId.dropFirst(5)) // Drop "mcp__"
        let parts = withoutPrefix.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)

        guard parts.count >= 1 else { return toolId }

        let serverName = toTitleCase(String(parts[0]))

        if parts.count >= 2 {
            // The second part starts with "_" which we need to drop
            let toolNameRaw = String(parts[1]).hasPrefix("_")
                ? String(String(parts[1]).dropFirst())
                : String(parts[1])
            let toolName = toTitleCase(toolNameRaw)
            return "\(serverName) - \(toolName)"
        }

        return serverName
    }

    /// Formats tool input dictionary for display
    /// e.g., ["repoName": "facebook/react", "question": "How does..."] → `repoName: "facebook/react", question: "How does..."`
    /// Truncates long values and limits number of args shown
    static func formatArgs(_ input: [String: String], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let truncatedValue: String
            if value.count > maxValueLength {
                truncatedValue = String(value.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = value
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }

    /// Formats tool input from Any dictionary (handles both String and non-String values)
    static func formatArgs(_ input: [String: Any], maxValueLength: Int = 30, maxArgs: Int = 3) -> String {
        guard !input.isEmpty else { return "" }

        let sortedKeys = input.keys.sorted()
        var formattedParts: [String] = []

        for key in sortedKeys.prefix(maxArgs) {
            guard let value = input[key] else { continue }

            let stringValue: String
            if let str = value as? String {
                stringValue = str
            } else if let num = value as? NSNumber {
                stringValue = num.stringValue
            } else if let bool = value as? Bool {
                stringValue = bool ? "true" : "false"
            } else {
                stringValue = String(describing: value)
            }

            let truncatedValue: String
            if stringValue.count > maxValueLength {
                truncatedValue = String(stringValue.prefix(maxValueLength)) + "..."
            } else {
                truncatedValue = stringValue
            }

            formattedParts.append("\(key): \"\(truncatedValue)\"")
        }

        var result = formattedParts.joined(separator: ", ")

        if sortedKeys.count > maxArgs {
            result += ", ..."
        }

        return result
    }
}
