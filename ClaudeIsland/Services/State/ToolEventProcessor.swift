//
//  ToolEventProcessor.swift
//  ClaudeIsland
//
//  Handles tool and subagent event processing logic.
//  Extracted from SessionStore to reduce complexity.
//

import Foundation
import os.log

// MARK: - ToolEventProcessor

/// Processes tool-related events and updates session state
enum ToolEventProcessor {
    // MARK: Internal

    // MARK: - Tool Tracking

    /// Process PreToolUse event for tool tracking
    static func processPreToolUse(
        event: HookEvent,
        session: inout SessionState,
    ) {
        guard let toolUseID = event.toolUseID, let toolName = event.tool else { return }

        session.toolTracker.startTool(id: toolUseID, name: toolName)

        let toolExists = session.chatItems.contains { $0.id == toolUseID }
        if !toolExists {
            let input = self.extractToolInput(from: event.toolInput)
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

    /// Process PostToolUse event for tool tracking
    static func processPostToolUse(
        event: HookEvent,
        session: inout SessionState,
    ) {
        guard let toolUseID = event.toolUseID else { return }

        session.toolTracker.completeTool(id: toolUseID, success: true)
        self.updateToolStatus(in: &session, toolID: toolUseID, status: .success)
    }

    // MARK: - Subagent Tracking

    /// Process PreToolUse event for subagent tracking
    static func processSubagentPreToolUse(
        event: HookEvent,
        session: inout SessionState,
    ) {
        guard let toolUseID = event.toolUseID else { return }

        if event.tool == "Task" {
            session.subagentState.startTask(taskToolID: toolUseID)
            Self.logger.debug("Started Task subagent tracking: \(toolUseID.prefix(12), privacy: .public)")
        } else if let toolName = event.tool, session.subagentState.hasActiveSubagent {
            Self.logger.debug("Adding subagent tool \(toolName, privacy: .public) to active Task")
            let input = self.extractToolInput(from: event.toolInput)
            let subagentTool = SubagentToolCall(
                id: toolUseID,
                name: toolName,
                input: input,
                status: .running,
                timestamp: Date(),
            )
            session.subagentState.addSubagentTool(subagentTool)
        }
    }

    /// Process PostToolUse event for subagent tracking
    static func processSubagentPostToolUse(
        event: HookEvent,
        session: inout SessionState,
    ) {
        guard let toolUseID = event.toolUseID else { return }

        if event.tool == "Task" {
            if let taskContext = session.subagentState.activeTasks[toolUseID] {
                Self.logger.debug("Task completing with \(taskContext.subagentTools.count) subagent tools")
                self.attachSubagentToolsToTask(
                    session: &session,
                    taskToolID: toolUseID,
                    subagentTools: taskContext.subagentTools,
                )
            } else {
                Self.logger.debug("Task completing but no taskContext found for \(toolUseID.prefix(12), privacy: .public)")
            }
            session.subagentState.stopTask(taskToolID: toolUseID)
        } else {
            session.subagentState.updateSubagentToolStatus(toolID: toolUseID, status: .success)
        }
    }

    /// Transfer all active subagent tools before stop/interrupt
    static func transferAllSubagentTools(session: inout SessionState, markAsInterrupted: Bool = false) {
        for (taskID, taskContext) in session.subagentState.activeTasks {
            var tools = taskContext.subagentTools
            if markAsInterrupted {
                for index in 0 ..< tools.count where tools[index].status == .running {
                    tools[index].status = .interrupted
                }
            }
            self.attachSubagentToolsToTask(
                session: &session,
                taskToolID: taskID,
                subagentTools: tools,
            )
        }
        session.subagentState = SubagentState()
    }

    // MARK: - Tool Status Updates

    /// Update tool status in session's chat items
    static func updateToolStatus(
        in session: inout SessionState,
        toolID: String,
        status: ToolStatus,
    ) {
        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == toolID,
               case var .toolCall(tool) = session.chatItems[i].type,
               tool.status == .waitingForApproval || tool.status == .running {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp,
                )
                return
            }
        }
        let count = session.chatItems.count
        Self.logger.warning("Tool \(toolID.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
    }

    /// Find the next tool waiting for approval
    static func findNextPendingTool(
        in session: SessionState,
        excluding toolID: String,
    ) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolID { continue }
            if case let .toolCall(tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    /// Mark all running tools as interrupted
    static func markRunningToolsInterrupted(session: inout SessionState) {
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
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ToolEvents")

    // MARK: - Private Helpers

    /// Attach subagent tools to a Task's ChatHistoryItem
    private static func attachSubagentToolsToTask(
        session: inout SessionState,
        taskToolID: String,
        subagentTools: [SubagentToolCall],
    ) {
        guard !subagentTools.isEmpty else { return }

        for i in 0 ..< session.chatItems.count {
            if session.chatItems[i].id == taskToolID,
               case var .toolCall(tool) = session.chatItems[i].type {
                tool.subagentTools = subagentTools
                session.chatItems[i] = ChatHistoryItem(
                    id: taskToolID,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp,
                )
                self.logger.debug("Attached \(subagentTools.count) subagent tools to Task \(taskToolID.prefix(12), privacy: .public)")
                break
            }
        }
    }

    /// Extract tool input from JSONValue dictionary
    private static func extractToolInput(from hookInput: [String: JSONValue]?) -> [String: String] {
        var input: [String: String] = [:]
        guard let hookInput else { return input }

        for (key, value) in hookInput {
            if let str = value.stringValue {
                input[key] = str
            } else if let num = value.intValue {
                input[key] = String(num)
            } else if let bool = value.boolValue {
                input[key] = bool ? "true" : "false"
            }
        }
        return input
    }
}
