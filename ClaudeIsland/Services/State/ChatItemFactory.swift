//
//  ChatItemFactory.swift
//  ClaudeIsland
//
//  Factory for creating ChatHistoryItem instances from message blocks.
//  Extracted from SessionStore for type body length compliance.
//

import Foundation

// MARK: - ItemCreationContext

/// Context for creating chat items, grouping related parameters
struct ItemCreationContext {
    let existingIDs: Set<String>
    let completedTools: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    var toolTracker: ToolTracker

    nonisolated mutating func markToolSeen(_ id: String) -> Bool {
        self.toolTracker.markSeen(id)
    }
}

// MARK: - ChatItemFactory

enum ChatItemFactory {
    // MARK: Internal

    /// Create a chat history item from a message block
    /// Returns nil if the item already exists or should be skipped
    nonisolated static func createItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        context: inout ItemCreationContext,
    ) -> ChatHistoryItem? {
        switch block {
        case let .text(text):
            self.createTextItem(
                text: text,
                message: message,
                blockIndex: blockIndex,
                existingIDs: context.existingIDs,
            )

        case let .toolUse(tool):
            self.createToolUseItem(tool: tool, message: message, context: &context)

        case let .thinking(text):
            self.createThinkingItem(
                text: text,
                message: message,
                blockIndex: blockIndex,
                existingIDs: context.existingIDs,
            )

        case .interrupted:
            self.createInterruptedItem(
                message: message,
                blockIndex: blockIndex,
                existingIDs: context.existingIDs,
            )
        }
    }

    // MARK: Private

    // MARK: - Private Helpers

    private nonisolated static func createTextItem(
        text: String,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>,
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-text-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }

        if message.role == .user {
            return ChatHistoryItem(id: itemID, type: .user(text), timestamp: message.timestamp)
        } else {
            return ChatHistoryItem(id: itemID, type: .assistant(text), timestamp: message.timestamp)
        }
    }

    private nonisolated static func createToolUseItem(
        tool: ToolUseBlock,
        message: ChatMessage,
        context: inout ItemCreationContext,
    ) -> ChatHistoryItem? {
        guard context.markToolSeen(tool.id) else { return nil }

        let isCompleted = context.completedTools.contains(tool.id)
        let status: ToolStatus = isCompleted ? .success : .running

        // Extract result text for completed tools
        var resultText: String?
        if isCompleted, let parserResult = context.toolResults[tool.id] {
            if let stdout = parserResult.stdout, !stdout.isEmpty {
                resultText = stdout
            } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                resultText = stderr
            } else if let content = parserResult.content, !content.isEmpty {
                resultText = content
            }
        }

        return ChatHistoryItem(
            id: tool.id,
            type: .toolCall(ToolCallItem(
                name: tool.name,
                input: tool.input,
                status: status,
                result: resultText,
                structuredResult: context.structuredResults[tool.id],
                subagentTools: [],
            )),
            timestamp: message.timestamp,
        )
    }

    private nonisolated static func createThinkingItem(
        text: String,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>,
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-thinking-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }
        return ChatHistoryItem(id: itemID, type: .thinking(text), timestamp: message.timestamp)
    }

    private nonisolated static func createInterruptedItem(
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>,
    ) -> ChatHistoryItem? {
        let itemID = "\(message.id)-interrupted-\(blockIndex)"
        guard !existingIDs.contains(itemID) else { return nil }
        return ChatHistoryItem(id: itemID, type: .interrupted, timestamp: message.timestamp)
    }
}
