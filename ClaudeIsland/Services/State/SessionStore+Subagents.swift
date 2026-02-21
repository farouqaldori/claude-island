//
//  SessionStore+Subagents.swift
//  ClaudeIsland
//
//  Subagent event handlers for SessionStore.
//  Extracted for type body length compliance.
//

import Foundation
import os

// MARK: - Subagent Event Handlers

extension SessionStore {
    /// Track subagent activity from hook events
    func trackSubagent(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseID = event.toolUseID {
                let description = event.toolInput?["description"]?.stringValue
                session.subagentState.startTask(taskToolID: toolUseID, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseID.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Handle subagent started event
    func handleSubagentStarted(sessionID: String, taskToolID: String) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.startTask(taskToolID: taskToolID)
        sessions[sessionID] = session
    }

    /// Handle subagent tool executed event
    func handleSubagentToolExecuted(sessionID: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionID] = session
    }

    /// Handle subagent tool completed event
    func handleSubagentToolCompleted(sessionID: String, toolID: String, status: ToolStatus) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.updateSubagentToolStatus(toolID: toolID, status: status)
        sessions[sessionID] = session
    }

    /// Handle subagent stopped event
    func handleSubagentStopped(sessionID: String, taskToolID: String) {
        guard var session = sessions[sessionID] else { return }
        session.subagentState.stopTask(taskToolID: taskToolID)
        sessions[sessionID] = session
    }
}
