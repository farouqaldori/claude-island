//
//  ChatMessage.swift
//  ClaudeIsland
//
//  Models for conversation messages parsed from JSONL
//

import Foundation

// MARK: - ChatMessage

nonisolated struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: ChatRole
    let timestamp: Date
    let content: [MessageBlock]

    /// Plain text content combined
    var textContent: String {
        self.content
            .compactMap { block in
                if case let .text(text) = block {
                    return text
                }
                return nil
            }
            .joined(separator: "\n")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ChatRole

nonisolated enum ChatRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

// MARK: - MessageBlock

nonisolated enum MessageBlock: Equatable, Identifiable, Sendable {
    case text(String)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted

    // MARK: Internal

    var id: String {
        switch self {
        case let .text(text):
            "text-\(text.prefix(20).hashValue)"
        case let .toolUse(block):
            "tool-\(block.id)"
        case let .thinking(text):
            "thinking-\(text.prefix(20).hashValue)"
        case .interrupted:
            "interrupted"
        }
    }

    /// Type prefix for generating stable IDs
    nonisolated var typePrefix: String {
        switch self {
        case .text: "text"
        case .toolUse: "tool"
        case .thinking: "thinking"
        case .interrupted: "interrupted"
        }
    }
}

// MARK: - ToolUseBlock

nonisolated struct ToolUseBlock: Equatable, Sendable {
    let id: String
    let name: String
    let input: [String: String]

    /// Short preview of the tool input
    var preview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return filePath
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(50))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        return self.input.values.first.map { String($0.prefix(50)) } ?? ""
    }
}
