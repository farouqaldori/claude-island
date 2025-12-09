//
//  ChatMessage.swift
//  ClaudeIsland
//
//  Models for conversation messages parsed from JSONL
//

import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: ChatRole
    let timestamp: Date
    let content: [MessageBlock]

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Plain text content combined
    var textContent: String {
        content.compactMap { block in
            if case .text(let text) = block {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }
}

enum ChatRole: String, Equatable {
    case user
    case assistant
    case system
}

enum MessageBlock: Equatable, Identifiable {
    case text(String)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted

    var id: String {
        switch self {
        case .text(let text):
            return "text-\(text.prefix(20).hashValue)"
        case .toolUse(let block):
            return "tool-\(block.id)"
        case .thinking(let text):
            return "thinking-\(text.prefix(20).hashValue)"
        case .interrupted:
            return "interrupted"
        }
    }

    /// Type prefix for generating stable IDs
    nonisolated var typePrefix: String {
        switch self {
        case .text: return "text"
        case .toolUse: return "tool"
        case .thinking: return "thinking"
        case .interrupted: return "interrupted"
        }
    }
}

struct ToolUseBlock: Equatable {
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
        return input.values.first.map { String($0.prefix(50)) } ?? ""
    }
}
