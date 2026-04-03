import Foundation

typealias GeminiEventHandler = @Sendable (GeminiEvent) -> Void

final class GeminiSessionMonitor {
    static let shared = GeminiSessionMonitor()
    private static let activeWindow: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.claudeisland.gemini-monitor", qos: .utility)
    private var scanTimer: DispatchSourceTimer?
    private var eventHandler: GeminiEventHandler?

    private let geminiTmpDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
            .appendingPathComponent("tmp")
    }()

    private struct StatusSnapshot: Equatable {
        let status: String
    }

    private var sessionStatuses: [String: StatusSnapshot] = [:]
    private var knownSessionDirs: [String: String] = [:]

    private init() {}

    func start(onEvent: @escaping GeminiEventHandler) {
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
        guard fm.fileExists(atPath: geminiTmpDir.path),
              let entries = try? fm.contentsOfDirectory(
                  at: geminiTmpDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        let geminiPids = ProcessTreeBuilder.shared.runningProcessPids(matchingAny: ["gemini"])
        let geminiWorkingDirectories = ProcessTreeBuilder.shared.runningProcessCwds(forPids: geminiPids)

        let threshold = Date().addingTimeInterval(-Self.activeWindow)
        var activeIds = Set<String>()

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let logsFile = entry.appendingPathComponent("logs.json")
            guard fm.fileExists(atPath: logsFile.path) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: logsFile.path)
            let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
            guard modDate >= threshold else { continue }

            guard let sessionMeta = parseSessionMeta(logsFile: logsFile, fallbackDir: entry.lastPathComponent) else { continue }
            guard !geminiPids.isEmpty else { continue }
            if !geminiWorkingDirectories.isEmpty, !geminiWorkingDirectories.contains(sessionMeta.cwd) {
                continue
            }
            activeIds.insert(sessionMeta.sessionId)
            knownSessionDirs[sessionMeta.sessionId] = sessionMeta.cwd

            let status = inferStatus(logsFile: logsFile)
            emitIfChanged(sessionId: sessionMeta.sessionId, cwd: sessionMeta.cwd, status: status, timestamp: modDate)
        }

        let missing = Set(sessionStatuses.keys).subtracting(activeIds)
        for sessionId in missing {
            let cwd = knownSessionDirs[sessionId] ?? FileManager.default.homeDirectoryForCurrentUser.path
            emitIfChanged(sessionId: sessionId, cwd: cwd, status: "ended", timestamp: Date())
            sessionStatuses.removeValue(forKey: sessionId)
        }
    }

    private func emitIfChanged(sessionId: String, cwd: String, status: String, timestamp: Date) {
        let snapshot = StatusSnapshot(status: status)
        guard sessionStatuses[sessionId] != snapshot else { return }
        sessionStatuses[sessionId] = snapshot
        eventHandler?(GeminiEvent(sessionId: sessionId, cwd: cwd, status: status, timestamp: timestamp))
    }

    private func parseSessionMeta(logsFile: URL, fallbackDir: String) -> (sessionId: String, cwd: String)? {
        guard let data = try? Data(contentsOf: logsFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let sessionId = first["sessionId"] as? String else {
            return nil
        }

        let cwd: String
        if let projectRoot = try? String(contentsOf: logsFile.deletingLastPathComponent().appendingPathComponent(".project_root"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectRoot.isEmpty {
            cwd = projectRoot
        } else {
            cwd = resolveProjectRoot(from: fallbackDir)
        }

        return (sessionId, cwd)
    }

    private func resolveProjectRoot(from dirName: String) -> String {
        if dirName.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }

        if dirName == "dusanzabrodsky" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }

        let historyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
            .appendingPathComponent("history")
            .appendingPathComponent(dirName)
            .appendingPathComponent(".project_root")

        if let projectRoot = try? String(contentsOf: historyRoot, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectRoot.isEmpty {
            return projectRoot
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func inferStatus(logsFile: URL) -> String {
        guard let data = try? Data(contentsOf: logsFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let last = array.last,
              let type = (last["type"] as? String)?.lowercased() else {
            return "idle"
        }

        switch type {
        case "user":
            return "processing"
        case "model", "assistant":
            return "waiting_for_input"
        default:
            return "idle"
        }
    }
}

typealias ProviderMonitorEventHandler = @Sendable (ProviderMonitorEvent) -> Void

final class ProviderSessionMonitor {
    static let shared = ProviderSessionMonitor()
    private static let activeWindow: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.claudeisland.provider-monitor", qos: .utility)
    private var scanTimer: DispatchSourceTimer?
    private var eventHandler: ProviderMonitorEventHandler?

    private struct Config {
        enum Source {
            case rollout(sessionMetaType: String)
            case copilotSessionState
        }

        let provider: AgentProvider
        let root: URL
        let subPath: String
        let source: Source
    }

    private let configs: [Config] = [
        Config(
            provider: .cursor,
            root: FileManager.default.homeDirectoryForCurrentUser,
            subPath: ".cursor/sessions",
            source: .rollout(sessionMetaType: "session_meta")
        ),
        Config(
            provider: .opencode,
            root: FileManager.default.homeDirectoryForCurrentUser,
            subPath: ".opencode/sessions",
            source: .rollout(sessionMetaType: "session_meta")
        ),
        Config(
            provider: .droid,
            root: FileManager.default.homeDirectoryForCurrentUser,
            subPath: ".droid/sessions",
            source: .rollout(sessionMetaType: "session_meta")
        ),
        Config(
            provider: .copilot,
            root: FileManager.default.homeDirectoryForCurrentUser,
            subPath: ".copilot/session-state",
            source: .copilotSessionState
        )
    ]

    private struct StatusSnapshot: Equatable {
        let status: String
        let tool: String?
        let toolUseId: String?
    }

    private var sessionStatuses: [String: StatusSnapshot] = [:]
    private var knownSessionDirs: [String: String] = [:]

    private init() {}

    func start(onEvent: @escaping ProviderMonitorEventHandler) {
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
        timer.schedule(deadline: .now() + .seconds(4), repeating: .seconds(4))
        timer.setEventHandler { [weak self] in self?.scanSessions() }
        timer.resume()
        scanTimer = timer
    }

    private func scanSessions() {
        let fm = FileManager.default
        let threshold = Date().addingTimeInterval(-Self.activeWindow)
        var activeKeys = Set<String>()
        let providerProcessState = providerProcessStateByType()

        for config in configs {
            let sessionsDir = config.root.appendingPathComponent(config.subPath)
            guard fm.fileExists(atPath: sessionsDir.path) else { continue }
            let processState = providerProcessState[config.provider] ?? (pids: [], cwds: Set<String>())

            switch config.source {
            case .rollout(let sessionMetaType):
                guard let enumerator = fm.enumerator(
                    at: sessionsDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let file as URL in enumerator {
                    guard file.pathExtension == "jsonl",
                          file.lastPathComponent.hasPrefix("rollout-") else { continue }

                    let attrs = try? fm.attributesOfItem(atPath: file.path)
                    let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
                    guard modDate >= threshold else { continue }

                    guard let meta = parseSessionMeta(file: file, sessionMetaType: sessionMetaType) else { continue }
                    if !isSessionProcessAlive(
                        provider: config.provider,
                        sessionDir: nil,
                        cwd: meta.cwd,
                        pids: processState.pids,
                        cwds: processState.cwds
                    ) {
                        continue
                    }
                    let key = monitorKey(provider: config.provider, sessionId: meta.sessionId)
                    activeKeys.insert(key)
                    knownSessionDirs[key] = meta.cwd

                    let inferred = inferStatus(file: file)
                    emitIfChanged(
                        provider: config.provider,
                        sessionId: meta.sessionId,
                        cwd: meta.cwd,
                        status: inferred.status,
                        tool: inferred.tool,
                        toolUseId: inferred.toolUseId,
                        toolInput: inferred.toolInput
                    )
                }
            case .copilotSessionState:
                scanCopilotSessions(
                    in: sessionsDir,
                    threshold: threshold,
                    processPids: processState.pids,
                    processCwds: processState.cwds,
                    activeKeys: &activeKeys
                )
            }
        }

        let missing = Set(sessionStatuses.keys).subtracting(activeKeys)
        for key in missing {
            guard let provider = providerFromMonitorKey(key) else { continue }
            let rawSessionId = sessionIdFromMonitorKey(key) ?? key
            let cwd = knownSessionDirs[key] ?? FileManager.default.homeDirectoryForCurrentUser.path
            emitIfChanged(provider: provider, sessionId: rawSessionId, cwd: cwd, status: "ended", tool: nil, toolUseId: nil, toolInput: nil)
            sessionStatuses.removeValue(forKey: key)
        }
    }

    private struct InferredState {
        let status: String
        let tool: String?
        let toolUseId: String?
        let toolInput: [String: AnyCodable]?
    }

    private func inferStatus(file: URL) -> InferredState {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let readBytes = min(UInt64(64 * 1024), fileSize)
        handle.seek(toFileOffset: fileSize > readBytes ? fileSize - readBytes : 0)

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }

        var activeToolId: String?
        var activeToolName: String?
        var pendingApprovalId: String?
        var pendingApprovalTool: String?
        var pendingApprovalInput: [String: AnyCodable]?
        var latestStatus = "idle"

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let itemType = payload["type"] as? String {
                if itemType == "function_call", let callId = payload["call_id"] as? String {
                    activeToolId = callId
                    activeToolName = payload["name"] as? String ?? "exec_command"
                    latestStatus = "processing"
                } else if itemType == "function_call_output",
                          let callId = payload["call_id"] as? String,
                          callId == activeToolId {
                    activeToolId = nil
                    activeToolName = nil
                    latestStatus = "waiting_for_input"
                } else if itemType == "custom_tool_call", let callId = payload["call_id"] as? String {
                    let status = (payload["status"] as? String ?? "").lowercased()
                    let toolName = payload["name"] as? String ?? "custom_tool"
                    if status == "waiting_for_approval" || status == "pending_approval" || status == "requires_approval" {
                        pendingApprovalId = callId
                        pendingApprovalTool = toolName
                        if let input = payload["input"] as? [String: Any] {
                            pendingApprovalInput = input.mapValues { AnyCodable($0) }
                        }
                        latestStatus = "waiting_for_approval"
                    } else if status == "completed" || status == "failed" || status == "cancelled" || status == "rejected" {
                        pendingApprovalId = nil
                        pendingApprovalTool = nil
                        pendingApprovalInput = nil
                        latestStatus = "waiting_for_input"
                    } else {
                        activeToolId = callId
                        activeToolName = toolName
                        latestStatus = "processing"
                    }
                } else if itemType == "message", let role = payload["role"] as? String {
                    latestStatus = role == "assistant" ? "waiting_for_input" : (role == "user" ? "processing" : latestStatus)
                }
            } else if type == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String {
                if eventType == "task_started" || eventType == "user_message" {
                    latestStatus = "processing"
                } else if eventType == "task_complete" {
                    latestStatus = "waiting_for_input"
                }
            }
        }

        if let pendingApprovalId, let pendingApprovalTool {
            return InferredState(status: "waiting_for_approval", tool: pendingApprovalTool, toolUseId: pendingApprovalId, toolInput: pendingApprovalInput)
        }

        if let activeToolId, let activeToolName {
            return InferredState(status: "processing", tool: activeToolName, toolUseId: activeToolId, toolInput: nil)
        }

        return InferredState(status: latestStatus, tool: nil, toolUseId: nil, toolInput: nil)
    }

    private func parseSessionMeta(file: URL, sessionMetaType: String) -> (sessionId: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 32 * 1024)
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == sessionMetaType,
                  let payload = json["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String else { continue }

            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                return (sessionId: sessionId, cwd: cwd)
            }
            if let projectRoot = payload["project_root"] as? String, !projectRoot.isEmpty {
                return (sessionId: sessionId, cwd: projectRoot)
            }
            return (sessionId: sessionId, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        return nil
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
        let key = monitorKey(provider: provider, sessionId: sessionId)
        let snapshot = StatusSnapshot(status: status, tool: tool, toolUseId: toolUseId)
        guard sessionStatuses[key] != snapshot else { return }
        sessionStatuses[key] = snapshot
        eventHandler?(ProviderMonitorEvent(
            provider: provider,
            sessionId: sessionId,
            cwd: cwd,
            status: status,
            tool: tool,
            toolUseId: toolUseId,
            toolInput: toolInput
        ))
    }

    private func monitorKey(provider: AgentProvider, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    private func providerFromMonitorKey(_ key: String) -> AgentProvider? {
        if key.hasPrefix("cursor:") { return .cursor }
        if key.hasPrefix("opencode:") { return .opencode }
        if key.hasPrefix("droid:") { return .droid }
        if key.hasPrefix("copilot:") { return .copilot }
        return nil
    }

    private func sessionIdFromMonitorKey(_ key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return parts[1]
    }

    private func scanCopilotSessions(
        in sessionStateDir: URL,
        threshold: Date,
        processPids: [Int],
        processCwds: Set<String>,
        activeKeys: inout Set<String>
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionStateDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let eventsFile = entry.appendingPathComponent("events.jsonl")
            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: eventsFile.path)
            let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
            guard modDate >= threshold else { continue }

            let meta = parseCopilotSessionMeta(sessionDir: entry)
            if !isSessionProcessAlive(
                provider: .copilot,
                sessionDir: entry,
                cwd: meta.cwd,
                pids: processPids,
                cwds: processCwds
            ) {
                continue
            }
            let inferred = inferCopilotStatus(file: eventsFile)
            let sessionId = meta.sessionId
            let key = monitorKey(provider: .copilot, sessionId: sessionId)
            activeKeys.insert(key)
            knownSessionDirs[key] = meta.cwd

            emitIfChanged(
                provider: .copilot,
                sessionId: sessionId,
                cwd: meta.cwd,
                status: inferred.status,
                tool: inferred.tool,
                toolUseId: inferred.toolUseId,
                toolInput: nil
            )
        }
    }

    private func providerProcessStateByType() -> [AgentProvider: (pids: [Int], cwds: Set<String>)] {
        var result: [AgentProvider: (pids: [Int], cwds: Set<String>)] = [:]

        for config in configs {
            let tokens = processNameTokens(for: config.provider)
            let pids = ProcessTreeBuilder.shared.runningProcessPids(matchingAny: tokens)
            let cwds = ProcessTreeBuilder.shared.runningProcessCwds(forPids: pids)
            result[config.provider] = (pids, cwds)
        }

        return result
    }

    private func processNameTokens(for provider: AgentProvider) -> [String] {
        switch provider {
        case .copilot:
            return ["copilot"]
        case .cursor:
            return ["cursor"]
        case .opencode:
            return ["opencode"]
        case .droid:
            return ["droid"]
        default:
            return [provider.rawValue]
        }
    }

    private func isSessionProcessAlive(
        provider: AgentProvider,
        sessionDir: URL?,
        cwd: String,
        pids: [Int],
        cwds: Set<String>
    ) -> Bool {
        if provider == .copilot,
           let sessionDir,
           hasLiveCopilotLock(in: sessionDir) {
            return true
        }

        guard !pids.isEmpty else { return false }

        if !cwds.isEmpty {
            return cwds.contains(cwd)
        }

        return true
    }

    private func hasLiveCopilotLock(in sessionDir: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { continue }
            let pidPart = name
                .replacingOccurrences(of: "inuse.", with: "")
                .replacingOccurrences(of: ".lock", with: "")
            guard let pid = Int(pidPart), isCopilotProcessAlive(pid) else { continue }
            return true
        }

        return false
    }

    private func isCopilotProcessAlive(_ pid: Int) -> Bool {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-p", String(pid), "-o", "comm="]) else {
            return false
        }
        let command = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !command.isEmpty && command.contains("copilot")
    }

    private func parseCopilotSessionMeta(sessionDir: URL) -> (sessionId: String, cwd: String) {
        let fallbackId = sessionDir.lastPathComponent
        let fallbackCwd = FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceFile = sessionDir.appendingPathComponent("workspace.yaml")

        guard let content = try? String(contentsOf: workspaceFile, encoding: .utf8) else {
            return (sessionId: fallbackId, cwd: fallbackCwd)
        }

        var sessionId = fallbackId
        var cwd = fallbackCwd

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("id:") {
                let value = line.dropFirst("id:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sessionId = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            } else if line.hasPrefix("cwd:") {
                let value = line.dropFirst("cwd:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    cwd = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }

        return (sessionId: sessionId, cwd: cwd)
    }

    private func inferCopilotStatus(file: URL) -> InferredState {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let readBytes = min(UInt64(160 * 1024), fileSize)
        handle.seek(toFileOffset: fileSize > readBytes ? fileSize - readBytes : 0)

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return InferredState(status: "idle", tool: nil, toolUseId: nil, toolInput: nil)
        }

        var activeToolId: String?
        var activeToolName: String?
        var latestStatus = "idle"

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "session.end":
                latestStatus = "ended"
                activeToolId = nil
                activeToolName = nil

            case "user.message", "assistant.turn_start":
                latestStatus = "processing"

            case "assistant.turn_end":
                latestStatus = "waiting_for_input"
                activeToolId = nil
                activeToolName = nil

            case "assistant.message":
                if let payload = json["data"] as? [String: Any],
                   let toolRequests = payload["toolRequests"] as? [[String: Any]],
                   !toolRequests.isEmpty {
                    latestStatus = "processing"
                } else {
                    latestStatus = "waiting_for_input"
                }

            case "tool.execution_start":
                if let payload = json["data"] as? [String: Any] {
                    activeToolId = payload["toolCallId"] as? String
                    activeToolName = payload["toolName"] as? String ?? "tool"
                }
                latestStatus = "processing"

            case "tool.execution_complete":
                if let payload = json["data"] as? [String: Any],
                   let completedToolId = payload["toolCallId"] as? String,
                   completedToolId == activeToolId {
                    activeToolId = nil
                    activeToolName = nil
                }
                latestStatus = "waiting_for_input"

            default:
                break
            }
        }

        if latestStatus == "ended" {
            return InferredState(status: "ended", tool: nil, toolUseId: nil, toolInput: nil)
        }
        if let activeToolId, let activeToolName {
            return InferredState(status: "processing", tool: activeToolName, toolUseId: activeToolId, toolInput: nil)
        }
        return InferredState(status: latestStatus, tool: nil, toolUseId: nil, toolInput: nil)
    }
}
