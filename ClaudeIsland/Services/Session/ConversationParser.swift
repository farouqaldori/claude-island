//
//  ConversationParser.swift
//  ClaudeIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

// MARK: - UsageInfo

/// Token usage information aggregated from assistant messages
nonisolated struct UsageInfo: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var totalTokens: Int {
        self.inputTokens + self.outputTokens
    }

    /// Formatted total for display (e.g., "12.5K", "1.2M")
    var formattedTotal: String {
        let total = self.totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1000 {
            return String(format: "%.1fK", Double(total) / 1000)
        }
        return "\(total)"
    }
}

// MARK: - ConversationInfo

nonisolated struct ConversationInfo: Equatable, Sendable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String? // "user", "assistant", or "tool"
    let lastToolName: String? // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String? // Fallback title when no summary
    let lastUserMessageDate: Date? // Timestamp of last user message (for stable sorting)
    let usage: UsageInfo? // Token usage information
}

// MARK: - ConversationParser

// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
actor ConversationParser {
    // MARK: Internal

    /// Parsed tool result data
    struct ToolResult: Sendable {
        // MARK: Lifecycle

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                    content?.contains("interrupted by user") == true ||
                    content?.contains("user doesn't want to proceed") == true
            )
        }

        // MARK: Internal

        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIDs: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Maximum file size (10 MB) before switching to incremental parsing
    /// Files larger than this will use streaming to avoid memory pressure
    static let maxFullLoadFileSize = 10_000_000

    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Parser")

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    ///
    /// Note: This method loads the entire file into memory for files under 10 MB.
    /// For larger files or incremental updates during active sessions, use `parseIncremental`
    /// instead which uses FileHandle for streaming.
    /// Full file loading is acceptable for smaller files because:
    /// 1. This is called infrequently (only when cache is stale)
    /// 2. The algorithm requires both forward and backward iteration
    /// 3. For very long conversations, the summary is typically updated, invalidating old data
    ///
    /// Note: File I/O helpers are nonisolated static methods, but when called synchronously
    /// from within an actor method, they still execute on the actor's executor. The async
    /// signature allows callers to await without blocking, but disk operations are not
    /// automatically dispatched to a background thread.
    func parse(sessionID: String, cwd: String) async -> ConversationInfo {
        let sessionFile = Self.sessionFilePath(sessionID: sessionID, cwd: cwd)

        // Check file attributes off-actor (file I/O)
        let fileInfo = Self.getFileInfo(path: sessionFile)
        guard let modDate = fileInfo.modificationDate else {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil,
                usage: nil,
            )
        }

        // Check cache (fast, actor-isolated)
        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        // Check file size to avoid memory pressure for very large conversation files
        if let fileSize = fileInfo.size, fileSize > Self.maxFullLoadFileSize {
            Self.logger.info("File size \(fileSize) exceeds max (\(Self.maxFullLoadFileSize)), using tail-based parsing")
            // For large files, read only the last portion to get recent info (off-actor)
            let content = Self.readLargeFileTail(path: sessionFile)
            let info = content.map { self.parseContent($0) } ?? ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil,
                usage: nil,
            )
            self.cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)
            return info
        }

        // Read file content off-actor
        guard let content = Self.readFileContent(path: sessionFile) else {
            return ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil,
                usage: nil,
            )
        }

        // Parse and cache (back on actor)
        let info = self.parseContent(content)
        self.cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionID: String, cwd: String) async -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionID: sessionID, cwd: cwd)

        guard Self.fileExists(path: sessionFile) else {
            return []
        }

        var state = self.incrementalState[sessionID] ?? IncrementalParseState()
        // Read new content off-actor, then process on-actor
        let parseResult = Self.readIncrementalContent(filePath: sessionFile, lastOffset: state.lastFileOffset)
        _ = self.processIncrementalContent(parseResult, state: &state)
        self.incrementalState[sessionID] = state

        return state.messages
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionID: String, cwd: String) async -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionID: sessionID, cwd: cwd)

        guard Self.fileExists(path: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIDs: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false,
            )
        }

        var state = self.incrementalState[sessionID] ?? IncrementalParseState()
        // Read new content off-actor, then process on-actor
        let parseResult = Self.readIncrementalContent(filePath: sessionFile, lastOffset: state.lastFileOffset)
        let newMessages = self.processIncrementalContent(parseResult, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        self.incrementalState[sessionID] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIDs: state.completedToolIDs,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected,
        )
    }

    /// Get set of completed tool IDs for a session
    func completedToolIDs(for sessionID: String) -> Set<String> {
        self.incrementalState[sessionID]?.completedToolIDs ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionID: String) -> [String: ToolResult] {
        self.incrementalState[sessionID]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionID: String) -> [String: ToolResultData] {
        self.incrementalState[sessionID]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionID: String) {
        self.incrementalState.removeValue(forKey: sessionID)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionID: String) -> Bool {
        guard var state = incrementalState[sessionID], state.clearPending else {
            return false
        }
        state.clearPending = false
        self.incrementalState[sessionID] = state
        return true
    }

    // MARK: Private

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIDs: Set<String> = []
        var toolIDToName: [String: String] = [:] // Map tool_use_id to tool name
        var completedToolIDs: Set<String> = [] // Tools that have received results
        var toolResults: [String: ToolResult] = [:] // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:] // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0 // Offset of last /clear command (0 = none or at start)
        var clearPending = false // True if a /clear was just detected
    }

    // MARK: - Nonisolated File I/O Helpers

    /// File info result from off-actor file attribute check
    private struct FileInfo: Sendable {
        let exists: Bool
        let modificationDate: Date?
        let size: Int?
    }

    /// Result from off-actor incremental file read
    private struct IncrementalReadResult: Sendable {
        let content: String?
        let newFileSize: UInt64
        let needsReset: Bool // true if file was truncated (size < lastOffset)
    }

    /// Tool input key mapping for display formatting
    private static let toolInputKeys: [String: String] = [
        "Read": "file_path",
        "Write": "file_path",
        "Edit": "file_path",
        "Bash": "command",
        "Grep": "pattern",
        "Glob": "pattern",
        "Task": "description",
        "WebFetch": "url",
        "WebSearch": "query",
    ]

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input else { return "" }

        if let key = toolInputKeys[toolName], let value = input[key] as? String {
            return ["Read", "Write", "Edit"].contains(toolName) ?
                (value as NSString).lastPathComponent : value
        }

        return input.values.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    /// Build session file path
    private static func sessionFilePath(sessionID: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionID + ".jsonl"
    }

    /// Check file existence off-actor
    private nonisolated static func fileExists(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Get file info (existence, modification date, size) off-actor
    private nonisolated static func getFileInfo(path: String) -> FileInfo {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path),
              let attrs = try? fileManager.attributesOfItem(atPath: path)
        else {
            return FileInfo(exists: false, modificationDate: nil, size: nil)
        }
        return FileInfo(
            exists: true,
            modificationDate: attrs[.modificationDate] as? Date,
            size: attrs[.size] as? Int,
        )
    }

    /// Read file content off-actor
    private nonisolated static func readFileContent(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Read the tail of a large file off-actor (last 2 MB)
    private nonisolated static func readLargeFileTail(path: String) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        do {
            let fileSize = try fileHandle.seekToEnd()
            // Read the last 2 MB to find recent messages and summary
            let readSize: UInt64 = min(2_000_000, fileSize)
            let startOffset = fileSize - readSize

            try fileHandle.seek(toOffset: startOffset)
            guard let data = try fileHandle.readToEnd(),
                  let content = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            // Skip partial first line if we didn't start at beginning
            if startOffset > 0, let firstNewline = content.firstIndex(of: "\n") {
                return String(content[content.index(after: firstNewline)...])
            }

            return content
        } catch {
            return nil
        }
    }

    /// Read new content from file since last offset (off-actor)
    private nonisolated static func readIncrementalContent(filePath: String, lastOffset: UInt64) -> IncrementalReadResult {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return IncrementalReadResult(content: nil, newFileSize: 0, needsReset: false)
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return IncrementalReadResult(content: nil, newFileSize: 0, needsReset: false)
        }

        // File was truncated - need to reset state
        if fileSize < lastOffset {
            return IncrementalReadResult(content: nil, newFileSize: fileSize, needsReset: true)
        }

        // No new content
        if fileSize == lastOffset {
            return IncrementalReadResult(content: nil, newFileSize: fileSize, needsReset: false)
        }

        do {
            try fileHandle.seek(toOffset: lastOffset)
        } catch {
            return IncrementalReadResult(content: nil, newFileSize: fileSize, needsReset: false)
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8)
        else {
            return IncrementalReadResult(content: nil, newFileSize: fileSize, needsReset: false)
        }

        return IncrementalReadResult(content: newContent, newFileSize: fileSize, needsReset: false)
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        // Use split() instead of components(separatedBy:) for better performance
        // split() with omittingEmptySubsequences (default true) avoids filter step
        let lines = content.split(separator: "\n").map { String($0) }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?

        // Token usage aggregation
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // First pass: aggregate usage from all assistant messages
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            // Parse usage from assistant messages containing "usage" field
            if let usage = json["usage"] as? [String: Any] {
                totalInput += usage["input_tokens"] as? Int ?? 0
                totalOutput += usage["output_tokens"] as? Int ?? 0
                totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            }
        }

        // Create usage info if we have any tokens
        let usageInfo = (totalInput + totalOutput > 0)
            ? UsageInfo(
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheReadTokens: totalCacheRead,
                cacheCreationTokens: totalCacheCreation,
            )
            : nil

        // Second pass: find first user message
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any],
                   let msgContent = message["content"] as? String {
                    if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                        firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                        break
                    }
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            let type = json["type"] as? String

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        if let msgContent = message["content"] as? String {
                            if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent
                                .hasPrefix("Caveat:") {
                                lastMessage = msgContent
                                lastMessageRole = type
                            }
                        } else if let contentArray = message["content"] as? [[String: Any]] {
                            for block in contentArray.reversed() {
                                let blockType = block["type"] as? String
                                if blockType == "tool_use" {
                                    let toolName = block["name"] as? String ?? "Tool"
                                    let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                    lastMessage = toolInput
                                    lastMessageRole = "tool"
                                    lastToolName = toolName
                                    break
                                } else if blockType == "text", let text = block["text"] as? String {
                                    if !text.hasPrefix("[Request interrupted by user") {
                                        lastMessage = text
                                        lastMessageRole = type
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            if let timestampStr = json["timestamp"] as? String {
                                lastUserMessageDate = formatter.date(from: timestampStr)
                            }
                            foundLastUserMessage = true
                        }
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            usage: usageInfo,
        )
    }

    /// Process incremental content that was read off-actor
    /// This runs on-actor to safely mutate state
    private func processIncrementalContent(_ readResult: IncrementalReadResult, state: inout IncrementalParseState) -> [ChatMessage] {
        // Handle file truncation (reset state)
        if readResult.needsReset {
            state = IncrementalParseState()
            state.lastFileOffset = readResult.newFileSize
            return []
        }

        // No new content - return empty array (not state.messages) since no NEW messages
        guard let newContent = readResult.content else {
            return []
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        var newMessages: [ChatMessage] = []

        // Use lazy split to avoid allocating full array for large files
        // String conversion is deferred - contains() works directly on Substring
        for line in newContent.lazy.split(separator: "\n") where !line.isEmpty {
            // Check conditions on Substring first (no allocation) before converting to String
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIDs = []
                state.toolIDToName = [:]
                state.completedToolIDs = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            // Only convert to String when we need to parse JSON (deferred allocation)
            if line.contains("\"tool_result\"") {
                let lineStr = String(line)
                if let lineData = lineStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseID = block["tool_use_id"] as? String {
                            state.completedToolIDs.insert(toolUseID)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseID] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError,
                            )

                            let toolName = topLevelToolName ?? state.toolIDToName[toolUseID]

                            if let toolUseResult,
                               let name = toolName {
                                let structured = ToolResultParser.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError,
                                )
                                state.structuredResults[toolUseID] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                let lineStr = String(line)
                if let lineData = lineStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIDs: &state.seenToolIDs, toolIDToName: &state.toolIDToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
            // Lines that don't match any condition are skipped without String allocation
        }

        state.lastFileOffset = readResult.newFileSize
        return newMessages
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIDs: inout Set<String>, toolIDToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String
        else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []
        blocks.reserveCapacity(4) // Most messages have 2-4 blocks

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolID = block["id"] as? String {
                            if seenToolIDs.contains(toolID) {
                                continue
                            }
                            seenToolIDs.insert(toolID)
                            if let toolName = block["name"] as? String {
                                toolIDToName[toolID] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks,
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String
        else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }
}

// swiftlint:enable type_body_length function_body_length cyclomatic_complexity
