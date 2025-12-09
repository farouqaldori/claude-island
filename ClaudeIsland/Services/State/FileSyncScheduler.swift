//
//  FileSyncScheduler.swift
//  ClaudeIsland
//
//  Handles debounced file sync scheduling for session JSONL files.
//  Extracted from SessionStore to reduce complexity.
//

import Foundation
import os.log

/// Manages debounced file sync operations for session data
actor FileSyncScheduler {
    /// Logger for file sync (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "FileSync")

    /// Pending sync tasks keyed by sessionId
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Debounce interval in nanoseconds (100ms)
    private let debounceNs: UInt64 = 100_000_000

    /// Callback type for when a sync should be performed
    typealias SyncHandler = @Sendable (String, String) async -> Void

    /// Schedule a debounced file sync for a session
    /// - Parameters:
    ///   - sessionId: The session to sync
    ///   - cwd: The working directory
    ///   - handler: Callback to perform the actual sync
    func schedule(sessionId: String, cwd: String, handler: @escaping SyncHandler) {
        // Cancel existing pending sync
        cancel(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [debounceNs] in
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }

            Self.logger.debug("Executing sync for session \(sessionId.prefix(8), privacy: .public)")
            await handler(sessionId, cwd)
        }
    }

    /// Cancel any pending sync for a session
    func cancel(sessionId: String) {
        if let existing = pendingSyncs.removeValue(forKey: sessionId) {
            existing.cancel()
            Self.logger.debug("Cancelled pending sync for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    /// Cancel all pending syncs
    func cancelAll() {
        for (_, task) in pendingSyncs {
            task.cancel()
        }
        pendingSyncs.removeAll()
    }

    /// Check if a sync is pending for a session
    func hasPendingSync(sessionId: String) -> Bool {
        pendingSyncs[sessionId] != nil
    }
}
