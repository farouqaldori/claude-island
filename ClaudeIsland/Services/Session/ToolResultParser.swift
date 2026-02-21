//
//  ToolResultParser.swift
//  ClaudeIsland
//
//  Static functions for parsing tool results from JSONL data into ToolResultData types.
//  Extracted from ConversationParser for type body length compliance.
//

import Foundation

// MARK: - ToolResultParser

enum ToolResultParser {
    // MARK: Internal

    // Parse tool result JSON into structured ToolResultData
    // Uses switch-based dispatch to avoid function reference isolation issues
    // swiftlint:disable:next cyclomatic_complexity
    nonisolated static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool,
    ) -> ToolResultData {
        switch toolName {
        case let name where name.hasPrefix("mcp__"):
            self.parseMCPResult(toolName: name, data: toolUseResult)
        case "Read": self.parseReadResult(toolUseResult)
        case "Edit": self.parseEditResult(toolUseResult)
        case "Write": self.parseWriteResult(toolUseResult)
        case "Bash": self.parseBashResult(toolUseResult)
        case "Grep": self.parseGrepResult(toolUseResult)
        case "Glob": self.parseGlobResult(toolUseResult)
        case "TodoWrite": self.parseTodoWriteResult(toolUseResult)
        case "Task": self.parseTaskResult(toolUseResult)
        case "WebFetch": self.parseWebFetchResult(toolUseResult)
        case "WebSearch": self.parseWebSearchResult(toolUseResult)
        case "AskUserQuestion": self.parseAskUserQuestionResult(toolUseResult)
        case "BashOutput": self.parseBashOutputResult(toolUseResult)
        case "KillShell": self.parseKillShellResult(toolUseResult)
        case "ExitPlanMode": self.parseExitPlanModeResult(toolUseResult)
        default: self.parseGenericResult(toolUseResult)
        }
    }

    // MARK: Private

    private nonisolated static func parseMCPResult(toolName: String, data: [String: Any]) -> ToolResultData {
        let parts = toolName.dropFirst(5).split(separator: "_", maxSplits: 2)
        let serverName = !parts.isEmpty ? String(parts[0]) : "unknown"
        let mcpToolName = parts.count > 1 ? String(parts[1].dropFirst()) : toolName
        let jsonString: String = if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys),
                                    let string = String(data: jsonData, encoding: .utf8) {
            string
        } else {
            "{}"
        }
        return .mcp(MCPResult(serverName: serverName, toolName: mcpToolName, rawResultJSON: jsonString))
    }

    private nonisolated static func parseGenericResult(_ data: [String: Any]) -> ToolResultData {
        let content = data["content"] as? String ??
            data["stdout"] as? String ??
            data["result"] as? String
        return .generic(GenericResult(rawContent: content))
    }

    // MARK: - Individual Tool Result Parsers

    private nonisolated static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0,
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0,
        ))
    }

    private nonisolated static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]?
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String]
                else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines,
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches,
        ))
    }

    private nonisolated static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]?
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String]
                else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines,
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches,
        ))
    }

    private nonisolated static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskID: data["backgroundTaskId"] as? String,
        ))
    }

    private nonisolated static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode = switch modeStr {
        case "content": .content
        case "count": .count
        default: .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int,
        ))
    }

    private nonisolated static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false,
        ))
    }

    private nonisolated static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String
                else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String,
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]]),
        ))
    }

    private nonisolated static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        .task(TaskResult(
            agentID: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int,
        ))
    }

    private nonisolated static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? "",
        ))
    }

    private nonisolated static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String
                else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? "",
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results,
        ))
    }

    private nonisolated static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { questionData -> QuestionItem? in
                guard let question = questionData["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = questionData["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String,
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: questionData["header"] as? String,
                    options: options,
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers,
        ))
    }

    private nonisolated static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        .bashOutput(BashOutputResult(
            shellID: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String,
        ))
    }

    private nonisolated static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        .killShell(KillShellResult(
            shellID: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? "",
        ))
    }

    private nonisolated static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false,
        ))
    }
}
