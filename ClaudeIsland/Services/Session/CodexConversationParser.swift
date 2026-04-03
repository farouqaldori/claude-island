import Foundation

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    struct IncrementalResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]
    }

    private let sessionsRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }()

    private var incrementalState: [String: IncrementalParseState] = [:]
    private var sessionFileCache: [String: String] = [:] // raw codex session id -> rollout file path

    private init() {}

    func parse(sessionId: String, cwd: String) -> ConversationInfo {
        _ = cwd
        let messages = parseFullConversation(sessionId: sessionId, cwd: "")
        return buildConversationInfo(from: messages)
    }

    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        _ = cwd
        guard let filePath = sessionFilePath(for: sessionId) else { return [] }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: filePath, state: &state)
        incrementalState[sessionId] = state
        return state.messages
    }

    func parseIncremental(sessionId: String, cwd: String) -> IncrementalResult {
        _ = cwd
        guard let filePath = sessionFilePath(for: sessionId) else {
            return IncrementalResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: filePath, state: &state)
        incrementalState[sessionId] = state

        return IncrementalResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: false
        )
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        incrementalState[sessionId]?.completedToolIds ?? []
    }

    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        incrementalState[sessionId]?.toolResults ?? [:]
    }

    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        incrementalState[sessionId]?.structuredResults ?? [:]
    }

    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return []
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return []
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return []
        }

        let lines = newContent.split(separator: "\n", omittingEmptySubsequences: false)
        let hasTrailingNewline = newContent.hasSuffix("\n")
        let previousMessageCount = state.messages.count
        var cursor = state.lastFileOffset

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let lineAnchor = cursor
            let endsWithNewline = index < lines.count - 1 || hasTrailingNewline
            cursor += UInt64(line.utf8.count + (endsWithNewline ? 1 : 0))

            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"] as? String)

            if type == "response_item" {
                guard let payload = json["payload"] as? [String: Any],
                      let itemType = payload["type"] as? String else { continue }
                processResponseItem(
                    payload: payload,
                    itemType: itemType,
                    timestamp: timestamp,
                    lineAnchor: lineAnchor,
                    state: &state
                )
            } else if type == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String {
                processEventMessage(
                    payload: payload,
                    eventType: eventType,
                    timestamp: timestamp,
                    lineAnchor: lineAnchor,
                    state: &state
                )
            }
        }

        state.lastFileOffset = fileSize
        return Array(state.messages.dropFirst(previousMessageCount))
    }

    private func processResponseItem(
        payload: [String: Any],
        itemType: String,
        timestamp: Date,
        lineAnchor: UInt64,
        state: inout IncrementalParseState
    ) {
        switch itemType {
        case "message":
            let role = (payload["role"] as? String ?? "").lowercased()
            guard role == "assistant" || role == "user" else { return }
            guard let text = extractMessageText(payload: payload), !text.isEmpty else { return }

            appendTextMessage(
                id: "codex-msg-\(lineAnchor)",
                role: role == "user" ? .user : .assistant,
                text: text,
                timestamp: timestamp,
                state: &state
            )

        case "function_call":
            guard let callId = payload["call_id"] as? String else { return }
            let rawName = payload["name"] as? String ?? "tool"
            let toolName = normalizeToolName(rawName)
            let input = parseFunctionArguments(payload["arguments"] as? String)
            appendToolCallIfNew(
                callId: callId,
                toolName: toolName,
                input: input,
                timestamp: timestamp,
                state: &state
            )

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = payload["output"] as? String
            state.completedToolIds.insert(callId)
            state.toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: nil,
                stderr: nil,
                isError: inferErrorFromOutput(output)
            )

        case "custom_tool_call":
            guard let callId = payload["call_id"] as? String else { return }
            let rawName = payload["name"] as? String ?? "custom_tool"
            let toolName = normalizeToolName(rawName)
            let input = parseCustomToolInput(payload["input"])
            appendToolCallIfNew(
                callId: callId,
                toolName: toolName,
                input: input,
                timestamp: timestamp,
                state: &state
            )

            let status = (payload["status"] as? String ?? "").lowercased()
            if status == "completed" || status == "failed" || status == "cancelled" || status == "rejected" {
                state.completedToolIds.insert(callId)
                let resultText = payload["output"] as? String
                let isError = status != "completed"
                state.toolResults[callId] = ConversationParser.ToolResult(
                    content: resultText,
                    stdout: nil,
                    stderr: nil,
                    isError: isError
                )
            }

        case "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = payload["output"] as? String
            state.completedToolIds.insert(callId)
            state.toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: nil,
                stderr: nil,
                isError: inferErrorFromOutput(output)
            )

        default:
            break
        }
    }

    private func processEventMessage(
        payload: [String: Any],
        eventType: String,
        timestamp: Date,
        lineAnchor: UInt64,
        state: inout IncrementalParseState
    ) {
        switch eventType {
        case "user_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return }
            appendTextMessage(
                id: "codex-user-\(lineAnchor)",
                role: .user,
                text: text,
                timestamp: timestamp,
                state: &state
            )

        case "agent_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return }
            appendTextMessage(
                id: "codex-assistant-\(lineAnchor)",
                role: .assistant,
                text: text,
                timestamp: timestamp,
                state: &state
            )

        case "exec_command_end":
            guard let callId = payload["call_id"] as? String else { return }
            state.completedToolIds.insert(callId)

            let stdout = payload["stdout"] as? String
            let stderr = payload["stderr"] as? String
            let aggregated = payload["aggregated_output"] as? String
            let exitCode = payload["exit_code"] as? Int

            let content = aggregated ?? stdout ?? stderr
            let isError = (exitCode != nil && exitCode != 0) || ((stderr ?? "").isEmpty == false)
            state.toolResults[callId] = ConversationParser.ToolResult(
                content: content,
                stdout: stdout,
                stderr: stderr,
                isError: isError
            )

        default:
            break
        }
    }

    private func appendToolCallIfNew(
        callId: String,
        toolName: String,
        input: [String: String],
        timestamp: Date,
        state: inout IncrementalParseState
    ) {
        if state.seenToolIds.contains(callId) {
            return
        }

        state.seenToolIds.insert(callId)
        state.toolIdToName[callId] = toolName

        let message = ChatMessage(
            id: "codex-tool-\(callId)",
            role: .assistant,
            timestamp: timestamp,
            content: [.toolUse(ToolUseBlock(id: callId, name: toolName, input: input))]
        )
        state.messages.append(message)
    }

    private func appendTextMessage(
        id: String,
        role: ChatRole,
        text: String,
        timestamp: Date,
        state: inout IncrementalParseState
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if let last = state.messages.last,
           last.role == role,
           messageText(last) == cleaned,
           abs(last.timestamp.timeIntervalSince(timestamp)) < 1 {
            return
        }

        let message = ChatMessage(
            id: id,
            role: role,
            timestamp: timestamp,
            content: [.text(cleaned)]
        )
        state.messages.append(message)
    }

    private func parseTimestamp(_ timestamp: String?) -> Date {
        guard let timestamp else { return Date() }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: timestamp) {
            return parsed
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: timestamp) ?? Date()
    }

    private func extractMessageText(payload: [String: Any]) -> String? {
        if let content = payload["content"] as? String {
            return content
        }

        if let contentArray = payload["content"] as? [[String: Any]] {
            let parts = contentArray.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }

        return nil
    }

    private func parseFunctionArguments(_ arguments: String?) -> [String: String] {
        guard let arguments, !arguments.isEmpty else { return [:] }
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["arguments": arguments]
        }
        return json.mapValues { stringify($0) }
    }

    private func parseCustomToolInput(_ input: Any?) -> [String: String] {
        guard let input else { return [:] }
        if let dict = input as? [String: Any] {
            return dict.mapValues { stringify($0) }
        }
        if let text = input as? String {
            return ["input": text]
        }
        return ["input": stringify(input)]
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            return num.stringValue
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{}"
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "[]"
        default:
            return String(describing: value)
        }
    }

    private func normalizeToolName(_ rawName: String) -> String {
        let normalized = rawName.lowercased()
        if normalized == "exec_command" {
            return "Bash"
        }
        if normalized == "ask_user" || normalized == "ask_user_question" || normalized == "askuserquestion" {
            return "AskUserQuestion"
        }
        return rawName
    }

    private func inferErrorFromOutput(_ output: String?) -> Bool {
        guard let output else { return false }
        let lower = output.lowercased()
        if lower.contains("process exited with code 0") || lower.contains("exit code 0") {
            return false
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exit code ") {
            return true
        }
        return false
    }

    private func buildConversationInfo(from messages: [ChatMessage]) -> ConversationInfo {
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var lastUserMessageDate: Date?

        for message in messages {
            if firstUserMessage == nil, message.role == .user {
                let text = messageText(message).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    firstUserMessage = truncateMessage(text, maxLength: 50)
                }
            }
            if message.role == .user {
                lastUserMessageDate = message.timestamp
            }
        }

        for message in messages.reversed() {
            for block in message.content.reversed() {
                switch block {
                case .toolUse(let tool):
                    lastMessage = truncateMessage(formatToolPreview(tool: tool), maxLength: 80)
                    lastMessageRole = "tool"
                    lastToolName = tool.name
                    return ConversationInfo(
                        summary: nil,
                        lastMessage: lastMessage,
                        lastMessageRole: lastMessageRole,
                        lastToolName: lastToolName,
                        firstUserMessage: firstUserMessage,
                        lastUserMessageDate: lastUserMessageDate
                    )
                case .text(let text):
                    lastMessage = truncateMessage(text, maxLength: 80)
                    lastMessageRole = message.role == .user ? "user" : "assistant"
                    return ConversationInfo(
                        summary: nil,
                        lastMessage: lastMessage,
                        lastMessageRole: lastMessageRole,
                        lastToolName: nil,
                        firstUserMessage: firstUserMessage,
                        lastUserMessageDate: lastUserMessageDate
                    )
                case .thinking, .interrupted:
                    continue
                }
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    private func formatToolPreview(tool: ToolUseBlock) -> String {
        if let command = tool.input["cmd"] ?? tool.input["command"] {
            return command
        }
        if let question = tool.input["question"] {
            return question
        }
        if let first = tool.input.values.first {
            return first
        }
        return ""
    }

    private func messageText(_ message: ChatMessage) -> String {
        let textParts = message.content.compactMap { block -> String? in
            if case .text(let text) = block {
                return text
            }
            return nil
        }
        return textParts.joined(separator: "\n")
    }

    private func truncateMessage(_ message: String, maxLength: Int) -> String {
        let cleaned = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    private func sessionFilePath(for sessionId: String) -> String? {
        let rawSessionId = stripCodexPrefix(sessionId)

        if let cached = sessionFileCache[rawSessionId],
           FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        guard FileManager.default.fileExists(atPath: sessionsRoot.path),
              let enumerator = FileManager.default.enumerator(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [(path: String, modDate: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((fileURL.path, modDate))
        }

        candidates.sort { $0.modDate > $1.modDate }

        for candidate in candidates {
            if codexSessionId(in: candidate.path) == rawSessionId {
                sessionFileCache[rawSessionId] = candidate.path
                return candidate.path
            }
        }

        return nil
    }

    private func codexSessionId(in filePath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 32 * 1024)
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let id = payload["id"] as? String else {
                continue
            }
            return id
        }

        return nil
    }

    private func stripCodexPrefix(_ sessionId: String) -> String {
        if sessionId.hasPrefix("codex:") {
            return String(sessionId.dropFirst("codex:".count))
        }
        return sessionId
    }
}
