import Foundation

typealias CodexEventHandler = @Sendable (CodexEvent) -> Void

final class CodexSessionMonitor {
    static let shared = CodexSessionMonitor()
    private static let activeWindow: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.claudeisland.codex-monitor", qos: .utility)
    private var scanTimer: DispatchSourceTimer?
    private var eventHandler: CodexEventHandler?

    private let codexSessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }()

    private struct StatusSnapshot: Equatable {
        let provider: AgentProvider
        let status: String
        let tool: String?
        let toolUseId: String?
    }

    /// Session id -> current status snapshot to avoid noisy duplicate emits.
    private var sessionStatuses: [String: StatusSnapshot] = [:]
    private var knownSessionDirs: [String: String] = [:]

    private init() {}

    func start(onEvent: @escaping CodexEventHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.eventHandler = onEvent
            self.scanSessions()
            self.startTimerIfNeeded()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.scanTimer?.cancel()
            self?.scanTimer = nil
            self?.eventHandler = nil
            self?.sessionStatuses.removeAll()
            self?.knownSessionDirs.removeAll()
        }
    }

    private func startTimerIfNeeded() {
        guard scanTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.scanSessions()
        }
        timer.resume()
        scanTimer = timer
    }

    private func scanSessions() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexSessionsDir.path) else { return }

        guard let enumerator = fm.enumerator(
            at: codexSessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let threshold = Date().addingTimeInterval(-Self.activeWindow)
        let activeCopilotCwds = activeCopilotWorkingDirectories(threshold: threshold)
        var activeKeys = Set<String>()

        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-") else { continue }

            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
            guard modDate >= threshold else { continue }

            guard let sessionMeta = parseSessionMeta(file: file) else { continue }
            let sessionProvider = provider(from: sessionMeta, activeCopilotCwds: activeCopilotCwds)

            let key = monitorKey(sessionId: sessionMeta.sessionId)
            activeKeys.insert(key)
            knownSessionDirs[key] = sessionMeta.cwd

            let status = inferStatus(file: file)
            emitIfChanged(
                provider: sessionProvider,
                sessionId: sessionMeta.sessionId,
                cwd: sessionMeta.cwd,
                status: status.status,
                tool: status.tool,
                toolUseId: status.toolUseId,
                toolInput: status.toolInput
            )
        }

        let missing = Set(sessionStatuses.keys).subtracting(activeKeys)
        for key in missing {
            guard let sessionId = sessionId(from: key),
                  let provider = provider(from: key) else {
                continue
            }
            let cwd = knownSessionDirs[key] ?? FileManager.default.homeDirectoryForCurrentUser.path
            emitIfChanged(
                provider: provider,
                sessionId: sessionId,
                cwd: cwd,
                status: "ended",
                tool: nil,
                toolUseId: nil,
                toolInput: nil
            )
            sessionStatuses.removeValue(forKey: key)
        }
    }

    private func emitIfChanged(
        provider: AgentProvider,
        sessionId: String,
        cwd: String,
        status: String,
        tool: String?,
        toolUseId: String?,
        toolInput: [String: AnyCodable]?
    ) {
        let key = monitorKey(sessionId: sessionId)
        let snapshot = StatusSnapshot(provider: provider, status: status, tool: tool, toolUseId: toolUseId)
        guard sessionStatuses[key] != snapshot else { return }
        sessionStatuses[key] = snapshot
        eventHandler?(CodexEvent(
            provider: provider,
            sessionId: sessionId,
            cwd: cwd,
            status: status,
            tool: tool,
            toolUseId: toolUseId,
            toolInput: toolInput
        ))
    }

    private func parseSessionMeta(file: URL) -> (sessionId: String, cwd: String, source: Any?, originator: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 32 * 1024)
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else {
                continue
            }
            return (sessionId, cwd, payload["source"], payload["originator"] as? String)
        }

        return nil
    }

    private func provider(
        from meta: (sessionId: String, cwd: String, source: Any?, originator: String?),
        activeCopilotCwds: Set<String>
    ) -> AgentProvider {
        // GitHub Copilot CLI writes Codex-format rollout files under ~/.codex/sessions.
        // We map those sessions to Copilot by source/originator markers, and
        // fall back to matching against active Copilot session-state working directories.
        if let sourceString = meta.source as? String, sourceString.localizedCaseInsensitiveContains("copilot") {
            return .copilot
        }
        if let sourceDict = meta.source as? [String: Any] {
            let sourceBlob = String(describing: sourceDict)
            if sourceBlob.localizedCaseInsensitiveContains("copilot") {
                return .copilot
            }
        }
        if let originator = meta.originator,
           originator.localizedCaseInsensitiveContains("copilot")
            || originator.localizedCaseInsensitiveContains("github")
        {
            return .copilot
        }
        if activeCopilotCwds.contains(normalizePath(meta.cwd)) {
            return .copilot
        }
        return .codex
    }

    private func activeCopilotWorkingDirectories(threshold: Date) -> Set<String> {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot")
            .appendingPathComponent("session-state")
        guard fm.fileExists(atPath: root.path),
              let entries = try? fm.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var cwds = Set<String>()
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let eventsFile = entry.appendingPathComponent("events.jsonl")
            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: eventsFile.path)
            let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
            guard modDate >= threshold else { continue }

            let workspaceFile = entry.appendingPathComponent("workspace.yaml")
            guard let content = try? String(contentsOf: workspaceFile, encoding: .utf8) else { continue }
            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("cwd:") else { continue }
                let value = line.dropFirst("cwd:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    cwds.insert(normalizePath(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
                }
                break
            }
        }
        return cwds
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func monitorKey(sessionId: String) -> String {
        "codex-monitor:\(sessionId)"
    }

    private func sessionId(from key: String) -> String? {
        let prefix = "codex-monitor:"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    private func provider(from key: String) -> AgentProvider? {
        sessionStatuses[key]?.provider
    }

    private struct InferredState {
        let status: String
        let tool: String?
        let toolUseId: String?
        let toolInput: [String: AnyCodable]?
    }

    private struct PendingApproval {
        let callId: String
        let toolName: String
        let toolInput: [String: AnyCodable]?
        let timestamp: Date
    }

    private struct ActiveTool {
        let callId: String
        let toolName: String
        let timestamp: Date
    }

    private enum SignalStatus {
        case processing
        case waitingForInput
    }

    private struct LatestSignal {
        let status: SignalStatus
        let timestamp: Date
    }

    private func inferStatus(file: URL) -> InferredState {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let readBytes = min(UInt64(64 * 1024), fileSize)
        if fileSize > readBytes {
            handle.seek(toFileOffset: fileSize - readBytes)
        } else {
            handle.seek(toFileOffset: 0)
        }

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }

        var activeToolsById: [String: ActiveTool] = [:]
        var pendingApprovalsById: [String: PendingApproval] = [:]
        var latestSignal: LatestSignal?

        func parseTimestamp(from json: [String: Any]) -> Date {
            guard let ts = json["timestamp"] as? String else { return Date() }
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFractional.date(from: ts) {
                return parsed
            }

            let withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
            return withoutFractional.date(from: ts) ?? Date()
        }

        func isApprovalPending(status: String, payload: [String: Any]) -> Bool {
            if status == "completed" || status == "failed" || status == "cancelled" || status == "rejected" {
                return false
            }

            if let requiresApproval = payload["requires_approval"] as? Bool {
                return requiresApproval
            }

            let approvalStatuses: Set<String> = [
                "waiting_for_approval",
                "awaiting_approval",
                "requires_approval",
                "approval_required",
                "pending_approval"
            ]
            return approvalStatuses.contains(status)
        }

        func isInteractiveQuestionTool(_ name: String) -> Bool {
            let normalized = name.lowercased()
            return normalized == "ask_user"
                || normalized == "ask_user_question"
                || normalized == "askuserquestion"
        }

        func normalizeToolName(_ name: String) -> String {
            isInteractiveQuestionTool(name) ? "AskUserQuestion" : name
        }

        func parseToolInput(payload: [String: Any], itemType: String) -> [String: AnyCodable]? {
            if itemType == "custom_tool_call",
               let input = payload["input"] as? [String: Any] {
                return input.mapValues { AnyCodable($0) }
            }

            if itemType == "function_call",
               let arguments = payload["arguments"] as? String,
               let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json.mapValues { AnyCodable($0) }
            }

            return nil
        }

        func setLatestSignal(_ candidate: LatestSignal, latestSignal: inout LatestSignal?) {
            guard let current = latestSignal else {
                latestSignal = candidate
                return
            }
            if candidate.timestamp >= current.timestamp {
                latestSignal = candidate
            }
        }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(from: json)

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let itemType = payload["type"] as? String {
                if itemType == "function_call" {
                    if let callId = payload["call_id"] as? String {
                        let rawToolName = payload["name"] as? String ?? "exec_command"
                        let toolName = normalizeToolName(rawToolName)
                        let toolInput = parseToolInput(payload: payload, itemType: itemType)

                        if isInteractiveQuestionTool(rawToolName) {
                            pendingApprovalsById[callId] = PendingApproval(
                                callId: callId,
                                toolName: toolName,
                                toolInput: toolInput,
                                timestamp: timestamp
                            )
                            activeToolsById.removeValue(forKey: callId)
                        } else {
                            activeToolsById[callId] = ActiveTool(
                                callId: callId,
                                toolName: toolName,
                                timestamp: timestamp
                            )
                        }

                        setLatestSignal(.init(status: .processing, timestamp: timestamp), latestSignal: &latestSignal)
                    }
                } else if itemType == "function_call_output" {
                    if let callId = payload["call_id"] as? String {
                        activeToolsById.removeValue(forKey: callId)
                        pendingApprovalsById.removeValue(forKey: callId)
                    }
                } else if itemType == "custom_tool_call" {
                    guard let callId = payload["call_id"] as? String else { continue }
                    let status = (payload["status"] as? String ?? "").lowercased()
                    let rawToolName = payload["name"] as? String ?? "custom_tool"
                    let toolName = normalizeToolName(rawToolName)
                    let toolInput = parseToolInput(payload: payload, itemType: itemType)
                    let isInteractive = isInteractiveQuestionTool(rawToolName)

                    if isApprovalPending(status: status, payload: payload)
                        || (isInteractive && status != "completed" && status != "failed" && status != "cancelled" && status != "rejected")
                    {
                        pendingApprovalsById[callId] = PendingApproval(
                            callId: callId,
                            toolName: toolName,
                            toolInput: toolInput,
                            timestamp: timestamp
                        )
                    } else if status == "completed" {
                        pendingApprovalsById.removeValue(forKey: callId)
                    } else {
                        pendingApprovalsById.removeValue(forKey: callId)
                    }
                } else if itemType == "custom_tool_call_output" {
                    if let callId = payload["call_id"] as? String {
                        pendingApprovalsById.removeValue(forKey: callId)
                    }
                }

                if itemType == "message",
                   let role = payload["role"] as? String,
                   role == "assistant" {
                    setLatestSignal(.init(status: .waitingForInput, timestamp: timestamp), latestSignal: &latestSignal)
                } else if itemType == "message",
                          let role = payload["role"] as? String,
                          role == "user" {
                    setLatestSignal(.init(status: .processing, timestamp: timestamp), latestSignal: &latestSignal)
                }
            } else if type == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String {
                if eventType == "exec_command_end",
                   let callId = payload["call_id"] as? String {
                    activeToolsById.removeValue(forKey: callId)
                }

                if eventType == "task_started" {
                    setLatestSignal(.init(status: .processing, timestamp: timestamp), latestSignal: &latestSignal)
                } else if eventType == "task_complete" {
                    setLatestSignal(.init(status: .waitingForInput, timestamp: timestamp), latestSignal: &latestSignal)
                } else if eventType == "user_message" {
                    setLatestSignal(.init(status: .processing, timestamp: timestamp), latestSignal: &latestSignal)
                }
            }
        }

        if let pending = pendingApprovalsById.values.sorted(by: { $0.timestamp > $1.timestamp }).first {
            return InferredState(
                status: "waiting_for_approval",
                tool: pending.toolName,
                toolUseId: pending.callId,
                toolInput: pending.toolInput
            )
        }

        if let active = activeToolsById.values.sorted(by: { $0.timestamp > $1.timestamp }).first {
            return InferredState(
                status: "processing",
                tool: active.toolName,
                toolUseId: active.callId,
                toolInput: nil
            )
        }

        if let signal = latestSignal {
            switch signal.status {
            case .processing:
                return InferredState(status: "processing", tool: nil, toolUseId: nil, toolInput: nil)
            case .waitingForInput:
                return InferredState(status: "waiting_for_input", tool: nil, toolUseId: nil, toolInput: nil)
            }
        }
        return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
    }
}
