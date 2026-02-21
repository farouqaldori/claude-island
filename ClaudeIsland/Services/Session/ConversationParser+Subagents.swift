//
//  ConversationParser+Subagents.swift
//  ClaudeIsland
//
//  Subagent tools parsing for ConversationParser.
//  Extracted for type body length compliance.
//

import Foundation

// MARK: - SubagentToolInfo

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Subagent Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(agentID: String, cwd: String) -> [SubagentToolInfo] {
        Self.parseSubagentToolsSync(agentID: agentID, cwd: cwd)
    }

    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(agentID: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentID.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentID + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8)
        else {
            return []
        }

        let completedToolIDs = self.parseCompletedToolIDs(from: content)
        return self.parseToolUseBlocks(from: content, completedToolIDs: completedToolIDs)
    }

    // MARK: Private Helpers

    private nonisolated static func parseCompletedToolIDs(from content: String) -> Set<String> {
        var completedToolIDs: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_result\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]]
            else {
                continue
            }

            for block in contentArray {
                if block["type"] as? String == "tool_result",
                   let toolUseID = block["tool_use_id"] as? String {
                    completedToolIDs.insert(toolUseID)
                }
            }
        }

        return completedToolIDs
    }

    private nonisolated static func parseToolUseBlocks(
        from content: String,
        completedToolIDs: Set<String>,
    ) -> [SubagentToolInfo] {
        var tools: [SubagentToolInfo] = []
        var seenToolIDs: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]]
            else {
                continue
            }

            for block in contentArray {
                if let tool = parseToolBlock(block, seenToolIDs: &seenToolIDs, completedToolIDs: completedToolIDs, json: json) {
                    tools.append(tool)
                }
            }
        }

        return tools
    }

    private nonisolated static func parseToolBlock(
        _ block: [String: Any],
        seenToolIDs: inout Set<String>,
        completedToolIDs: Set<String>,
        json: [String: Any],
    ) -> SubagentToolInfo? {
        guard block["type"] as? String == "tool_use",
              let toolID = block["id"] as? String,
              let toolName = block["name"] as? String,
              !seenToolIDs.contains(toolID)
        else {
            return nil
        }

        seenToolIDs.insert(toolID)

        let input = self.parseToolInput(block["input"] as? [String: Any])
        let isCompleted = completedToolIDs.contains(toolID)
        let timestamp = json["timestamp"] as? String

        return SubagentToolInfo(
            id: toolID,
            name: toolName,
            input: input,
            isCompleted: isCompleted,
            timestamp: timestamp,
        )
    }

    private nonisolated static func parseToolInput(_ inputDict: [String: Any]?) -> [String: String] {
        guard let inputDict else { return [:] }

        var input: [String: String] = [:]
        for (key, value) in inputDict {
            if let strValue = value as? String {
                input[key] = strValue
            } else if let intValue = value as? Int {
                input[key] = String(intValue)
            } else if let boolValue = value as? Bool {
                input[key] = boolValue ? "true" : "false"
            }
        }
        return input
    }
}
