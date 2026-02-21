//
//  SessionStore+PeriodicCheck.swift
//  ClaudeIsland
//
//  Periodic session status checking to detect terminated processes.
//

import Foundation

extension SessionStore {
    // MARK: - Periodic Status Check

    /// Start periodic status checking
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        statusCheckTask = Task(name: "periodic-status-check") { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.statusCheckInterval)
                guard !Task.isCancelled else { break }
                await self.recheckAllSessions()
            }
        }
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
    }

    /// Check all sessions for process termination
    func recheckAllSessions() async {
        // Take snapshot before iteration to avoid mutating dictionary during async loop
        let sessionsSnapshot = sessions

        for (sessionID, session) in sessionsSnapshot {
            // Skip ended sessions
            guard session.phase != .ended else { continue }

            // Check if process is still running
            if let pid = session.pid, !isProcessRunning(pid: pid) {
                await process(.sessionEnded(sessionID: sessionID))
                continue
            }

            // Refresh state for active sessions
            if session.phase == .processing || session.phase.isWaitingForApproval {
                scheduleFileSync(sessionID: sessionID, cwd: session.cwd)
            }
        }
    }

    /// Check if a process is running using kill(pid, 0)
    /// Returns true if process exists (even if we lack permission to signal it)
    nonisolated func isProcessRunning(pid: Int) -> Bool {
        if kill(Int32(pid), 0) == 0 {
            return true
        }
        // EPERM means process exists but we lack permission - treat as running
        // ESRCH means no such process - treat as not running
        return errno == EPERM
    }
}
