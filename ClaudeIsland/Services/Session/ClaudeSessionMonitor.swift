//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Uses @Observable for efficient property-level change tracking (macOS 14+).
//

import AppKit
import Foundation
import Observation
import Synchronization

// MARK: - ClaudeSessionMonitor

/// Session monitor using modern @Observable macro for efficient SwiftUI updates.
/// Subscribes to SessionStore's AsyncStream to receive session state changes.
@Observable
final class ClaudeSessionMonitor {
    // MARK: Lifecycle

    init() {
        self.sessionsTask = Task(name: "sessions-stream") { [weak self] in
            let stream = SessionStore.shared.sessionsStream()
            for await sessions in stream {
                self?.updateFromSessions(sessions)
            }
        }

        InterruptWatcherManager.shared.onInterrupt = { sessionID in
            Task(name: "interrupt-detected") { @MainActor in
                await SessionStore.shared.process(.interruptDetected(sessionID: sessionID))
                InterruptWatcherManager.shared.stopWatching(sessionID: sessionID)
            }
        }
    }

    // MARK: Internal

    var instances: [SessionState] = []
    var pendingInstances: [SessionState] = []

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                // HookSocketServer calls this callback on its internal socket queue.
                // Single MainActor hop handles all event processing.
                Task(name: "hook-event") { @MainActor [weak self] in
                    await self?.handleHookEvent(event)
                }
            },
            onPermissionFailure: { [weak self] sessionID, toolUseID in
                Task(name: "permission-failure") { @MainActor [weak self] in
                    await self?.handlePermissionFailure(sessionID: sessionID, toolUseID: toolUseID)
                }
            },
        )

        // Start periodic session status check
        Task(name: "start-periodic-check") {
            await SessionStore.shared.startPeriodicStatusCheck()
        }
    }

    func stopMonitoring() {
        self.sessionsTask?.cancel()
        self.sessionsTask = nil
        self.cancelAllTasks()
        HookSocketServer.shared.stop()

        // Stop periodic session status check
        Task(name: "stop-periodic-check") {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionID: String) {
        Task(name: "approve-permission") {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "allow",
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionID: sessionID, toolUseID: permission.toolUseID),
            )
        }
    }

    func denyPermission(sessionID: String, reason: String?) {
        Task(name: "deny-permission") {
            guard let session = await SessionStore.shared.session(for: sessionID),
                  let permission = session.activePermission
            else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseID: permission.toolUseID,
                decision: "deny",
                reason: reason,
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionID: sessionID, toolUseID: permission.toolUseID, reason: reason),
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionID: String) {
        Task(name: "archive-session") {
            await SessionStore.shared.process(.sessionEnded(sessionID: sessionID))
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionID: String, cwd: String) {
        Task(name: "load-history") {
            await SessionStore.shared.process(.loadHistory(sessionID: sessionID, cwd: cwd))
        }
    }

    // MARK: Private

    /// Task for sessions stream subscription
    @ObservationIgnored private var sessionsTask: Task<Void, Never>?

    /// Active tasks that should be cancelled when monitoring stops
    /// Uses Mutex for thread-safe access per Swift 6 patterns
    @ObservationIgnored private let activeTasks = Mutex<[UUID: Task<Void, Never>]>([:])

    /// Handle hook event - unified async handler to reduce executor hops
    private func handleHookEvent(_ event: HookEvent) async {
        // Process the hook event (hops to SessionStore actor)
        let task = Task(name: "process-hook-event") {
            await SessionStore.shared.process(.hookReceived(event))
        }
        self.trackTask(task)

        // Start/stop interrupt watcher (already on MainActor - no Task needed)
        if event.sessionPhase == .processing {
            InterruptWatcherManager.shared.startWatching(
                sessionID: event.sessionID,
                cwd: event.cwd,
            )
        }

        if event.status == "ended" {
            InterruptWatcherManager.shared.stopWatching(sessionID: event.sessionID)
        }

        // Cancel pending permissions (nonisolated - no hop needed)
        if event.event == "Stop" {
            HookSocketServer.shared.cancelPendingPermissions(sessionID: event.sessionID)
        }

        if event.event == "PostToolUse", let toolUseID = event.toolUseID {
            HookSocketServer.shared.cancelPendingPermission(toolUseID: toolUseID)
        }
    }

    /// Handle permission socket failure - unified async handler
    private func handlePermissionFailure(sessionID: String, toolUseID: String) async {
        let task = Task(name: "process-permission-failure") {
            await SessionStore.shared.process(
                .permissionSocketFailed(sessionID: sessionID, toolUseID: toolUseID),
            )
        }
        self.trackTask(task)
    }

    /// Track a task for cancellation on stop
    private func trackTask(_ task: Task<Void, Never>) {
        let id = UUID()
        self.activeTasks.withLock { $0[id] = task }

        // Auto-remove when task completes
        Task(name: "task-cleanup") {
            _ = await task.result
            _ = self.activeTasks.withLock { $0.removeValue(forKey: id) }
        }
    }

    /// Cancel all tracked tasks
    private func cancelAllTasks() {
        let tasks = self.activeTasks.withLock { tasks -> [Task<Void, Never>] in
            let values = Array(tasks.values)
            tasks.removeAll()
            return values
        }

        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        self.instances = sessions
        self.pendingInstances = sessions.filter(\.needsAttention)
    }
}
