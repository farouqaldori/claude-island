//
//  AgentFileWatcher.swift
//  ClaudeIsland
//
//  Watches agent JSONL files for real-time subagent tool updates.
//  Each Task tool gets its own watcher for its agent file.
//

import Foundation
import os.log

// MARK: - AgentFileWatcher

/// Watches a single agent JSONL file for tool updates.
/// Actor provides thread-safe access to mutable state without manual queue synchronization.
actor AgentFileWatcher {
    // MARK: Lifecycle

    init(
        sessionID: String,
        taskToolID: String,
        agentID: String,
        cwd: String,
        onToolsUpdate: @escaping @Sendable (String, String, [SubagentToolInfo]) -> Void,
    ) {
        self.sessionID = sessionID
        self.taskToolID = taskToolID
        self.agentID = agentID
        self.cwd = cwd
        self.onToolsUpdate = onToolsUpdate

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentID + ".jsonl"
    }

    deinit {
        // Cancel dispatch sources — cancel handlers will close file handles
        if let source {
            source.cancel()
        }
    }

    // MARK: Internal

    /// Logger for agent file watcher
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "AgentFileWatcher")

    /// Start watching the agent file
    func start() {
        self.startWatching()
    }

    /// Stop watching
    func stop() {
        self.stopInternal()
    }

    // MARK: Private

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionID: String
    private let taskToolID: String
    private let agentID: String
    private let cwd: String
    private let filePath: String

    /// Callback for tool updates (replaces delegate pattern)
    private let onToolsUpdate: @Sendable (String, String, [SubagentToolInfo]) -> Void

    /// Track seen tool IDs to avoid duplicates
    private var seenToolIDs: Set<String> = []

    private func startWatching() {
        self.stopInternal()

        guard FileManager.default.fileExists(atPath: self.filePath),
              let handle = FileHandle(forReadingAtPath: self.filePath)
        else {
            Self.logger.warning("Failed to open agent file: \(self.filePath, privacy: .public)")
            return
        }

        self.fileHandle = handle
        self.lastOffset = 0
        self.parseTools()

        do {
            self.lastOffset = try handle.seekToEnd()
        } catch {
            Self.logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fd = handle.fileDescriptor
        // DispatchSource uses its own queue for I/O — re-enter actor via Task
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated),
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task(name: "agent-parse-tools") { await self.parseTools() }
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            Task(name: "agent-cleanup-handle") { await self.cleanupFileHandle() }
        }

        self.source = newSource
        newSource.resume()

        Self.logger
            .debug(
                "Started watching agent file: \(self.agentID.prefix(8), privacy: .public) for task: \(self.taskToolID.prefix(12), privacy: .public)",
            )
    }

    private func parseTools() {
        let tools = ConversationParser.parseSubagentToolsSync(agentID: self.agentID, cwd: self.cwd)

        let newTools = tools.filter { !self.seenToolIDs.contains($0.id) }
        guard !newTools.isEmpty || tools.count != self.seenToolIDs.count else { return }

        self.seenToolIDs = Set(tools.map(\.id))
        Self.logger.debug("Agent \(self.agentID.prefix(8), privacy: .public) has \(tools.count) tools")

        let sessionID = self.sessionID
        let taskToolID = self.taskToolID
        let callback = self.onToolsUpdate
        Task(name: "agent-tools-update") { @MainActor in
            callback(sessionID, taskToolID, tools)
        }
    }

    private func cleanupFileHandle() {
        try? self.fileHandle?.close()
        self.fileHandle = nil
    }

    private func stopInternal() {
        guard let existingSource = source else { return }
        Self.logger.debug("Stopped watching agent file: \(self.agentID.prefix(8), privacy: .public)")
        existingSource.cancel()
        self.source = nil
    }
}

// MARK: - AgentFileWatcherManager

/// Manages agent file watchers for active Task tools.
/// Implicitly MainActor-isolated (SE-0466 default) — all access is MainActor-local.
class AgentFileWatcherManager {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = AgentFileWatcherManager()

    /// Callback for tool updates — set by AgentFileWatcherBridge
    var onToolsUpdate: (@Sendable (String, String, [SubagentToolInfo]) -> Void)?

    func startWatching(sessionID: String, taskToolID: String, agentID: String, cwd: String) {
        let key = "\(sessionID)-\(taskToolID)"
        guard self.watchers[key] == nil else { return }

        guard let callback = self.onToolsUpdate else {
            AgentFileWatcher.logger.warning("No onToolsUpdate callback set — cannot start watcher")
            return
        }

        let watcher = AgentFileWatcher(
            sessionID: sessionID,
            taskToolID: taskToolID,
            agentID: agentID,
            cwd: cwd,
            onToolsUpdate: callback,
        )
        Task(name: "agent-watcher-start") { await watcher.start() }
        self.watchers[key] = watcher

        AgentFileWatcher.logger.info("Started agent watcher for task \(taskToolID.prefix(12), privacy: .public)")
    }

    /// Stop watching a specific Task's agent file
    func stopWatching(sessionID: String, taskToolID: String) {
        let key = "\(sessionID)-\(taskToolID)"
        if let watcher = self.watchers[key] {
            Task(name: "agent-watcher-stop") { await watcher.stop() }
        }
        self.watchers.removeValue(forKey: key)
    }

    /// Stop all watchers for a session
    func stopWatchingSession(sessionID: String) {
        let keysToRemove = self.watchers.keys.filter { $0.hasPrefix(sessionID) }
        for key in keysToRemove {
            if let watcher = self.watchers[key] {
                Task(name: "agent-watcher-stop") { await watcher.stop() }
            }
            self.watchers.removeValue(forKey: key)
        }
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in self.watchers {
            Task(name: "agent-watcher-stop") { await watcher.stop() }
        }
        self.watchers.removeAll()
    }

    /// Check if we're watching a Task's agent file
    func isWatching(sessionID: String, taskToolID: String) -> Bool {
        let key = "\(sessionID)-\(taskToolID)"
        return self.watchers[key] != nil
    }

    // MARK: Private

    /// Active watchers keyed by "sessionId-taskToolId"
    private var watchers: [String: AgentFileWatcher] = [:]
}

// MARK: - AgentFileWatcherBridge

/// Bridge between AgentFileWatcherManager and SessionStore.
/// Converts tool update callbacks into SessionEvent processing.
/// Implicitly MainActor-isolated (SE-0466 default) — all access is MainActor-local.
class AgentFileWatcherBridge {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = AgentFileWatcherBridge()

    func setup() {
        AgentFileWatcherManager.shared.onToolsUpdate = { sessionID, taskToolID, tools in
            Task(name: "agent-file-update") {
                await SessionStore.shared.process(
                    .agentFileUpdated(sessionID: sessionID, taskToolID: taskToolID, tools: tools),
                )
            }
        }
    }
}
