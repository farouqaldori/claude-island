//
//  JSONLInterruptWatcher.swift
//  ClaudeIsland
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

// MARK: - JSONLInterruptWatcher

/// Watches a session's JSONL file for interrupt patterns in real-time.
/// Actor provides thread-safe access to mutable state without manual queue synchronization.
actor JSONLInterruptWatcher {
    // MARK: Lifecycle

    init(sessionID: String, cwd: String, onInterrupt: @escaping @Sendable (String) -> Void) {
        self.sessionID = sessionID
        self.onInterrupt = onInterrupt
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.directoryPath = NSHomeDirectory() + "/.claude/projects/" + projectDir
        self.filePath = self.directoryPath + "/" + sessionID + ".jsonl"
    }

    deinit {
        // Cancel the sources — cancel handlers will close the file handles
        if let source {
            source.cancel()
        }
        if let directorySource {
            directorySource.cancel()
        }
    }

    // MARK: Internal

    /// Start watching the JSONL file for interrupts
    func start() {
        self.startWatching()
    }

    /// Stop watching
    func stop() {
        self.stopInternal()
    }

    // MARK: Private

    /// Logger for interrupt watcher
    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Interrupt")

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private nonisolated static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user",
    ]

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private let sessionID: String
    private let filePath: String
    private let directoryPath: String

    /// Callback for interrupt detection (replaces delegate pattern)
    private let onInterrupt: @Sendable (String) -> Void

    private func startWatching() {
        self.stopInternal()

        // Try to watch the file directly
        if FileManager.default.fileExists(atPath: self.filePath) {
            self.startFileWatcher()
        } else {
            // File doesn't exist yet - watch the parent directory
            self.startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            Self.logger.warning("Failed to open file: \(self.filePath, privacy: .public)")
            return
        }

        self.fileHandle = handle

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
            queue: .global(qos: .userInteractive),
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task(name: "interrupt-check") { await self.checkForInterrupt() }
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            Task(name: "interrupt-cleanup-handle") { await self.cleanupFileHandle() }
        }

        self.source = newSource
        newSource.resume()

        Self.logger.debug("Started watching file: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func startDirectoryWatcher() {
        // Ensure the directory exists
        guard FileManager.default.fileExists(atPath: self.directoryPath) else {
            Self.logger.warning("Directory doesn't exist: \(self.directoryPath, privacy: .public)")
            return
        }

        guard let handle = FileHandle(forReadingAtPath: self.directoryPath) else {
            Self.logger.warning("Failed to open directory for watching: \(self.directoryPath, privacy: .public)")
            return
        }

        self.directoryHandle = handle
        let fd = handle.fileDescriptor

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .userInteractive),
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task(name: "interrupt-check-appearance") { await self.checkForFileAppearance() }
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            Task(name: "interrupt-cleanup-dir") { await self.cleanupDirectoryHandle() }
        }

        self.directorySource = newSource
        newSource.resume()

        Self.logger.debug("Started watching directory for file appearance: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func checkForFileAppearance() {
        // Check if the file now exists
        guard FileManager.default.fileExists(atPath: self.filePath) else {
            return
        }

        Self.logger.debug("File appeared, switching to file watcher: \(self.sessionID.prefix(8), privacy: .public)")

        // Stop directory watcher
        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }

        // Start file watcher
        self.startFileWatcher()
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > self.lastOffset else { return }

        do {
            try handle.seek(toOffset: self.lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8)
        else {
            return
        }

        self.lastOffset = currentSize

        // Use split with early exit - avoids full array allocation when interrupt found early
        for line in newContent.split(separator: "\n", omittingEmptySubsequences: true)
            where self.isInterruptLine(line) {
            Self.logger.info("Detected interrupt in session: \(self.sessionID.prefix(8), privacy: .public)")
            let sessionID = self.sessionID
            let callback = self.onInterrupt
            Task(name: "interrupt-notify") { @MainActor in
                callback(sessionID)
            }
            return
        }
    }

    private nonisolated func isInterruptLine(_ line: some StringProtocol) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
                line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            if Self.interruptContentPatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    private func cleanupFileHandle() {
        try? self.fileHandle?.close()
        self.fileHandle = nil
    }

    private func cleanupDirectoryHandle() {
        try? self.directoryHandle?.close()
        self.directoryHandle = nil
    }

    private func stopInternal() {
        // Stop file watcher
        if let existingSource = source {
            existingSource.cancel()
            self.source = nil
        }
        // Stop directory watcher
        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }
        // fileHandle and directoryHandle closed by cancel handlers
        Self.logger.debug("Stopped watching: \(self.sessionID.prefix(8), privacy: .public)...")
    }
}

// MARK: - InterruptWatcherManager

/// Manages interrupt watchers for all active sessions.
/// Implicitly MainActor-isolated (SE-0466 default) — all access is MainActor-local.
class InterruptWatcherManager {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = InterruptWatcherManager()

    /// Callback for interrupt detection — set by ClaudeSessionMonitor
    var onInterrupt: (@Sendable (String) -> Void)?

    func startWatching(sessionID: String, cwd: String) {
        guard self.watchers[sessionID] == nil else { return }

        guard let callback = self.onInterrupt else { return }

        let watcher = JSONLInterruptWatcher(sessionID: sessionID, cwd: cwd, onInterrupt: callback)
        Task(name: "interrupt-watcher-start") { await watcher.start() }
        self.watchers[sessionID] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionID: String) {
        if let watcher = self.watchers[sessionID] {
            Task(name: "interrupt-watcher-stop") { await watcher.stop() }
        }
        self.watchers.removeValue(forKey: sessionID)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in self.watchers {
            Task(name: "interrupt-watcher-stop") { await watcher.stop() }
        }
        self.watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionID: String) -> Bool {
        self.watchers[sessionID] != nil
    }

    // MARK: Private

    private var watchers: [String: JSONLInterruptWatcher] = [:]
}
