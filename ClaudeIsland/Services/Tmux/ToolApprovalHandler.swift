//
//  ToolApprovalHandler.swift
//  ClaudeIsland
//
//  Handles Claude tool approval operations via tmux
//

import Foundation
import os.log

/// Handles tool approval and rejection for Claude instances
actor ToolApprovalHandler {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Approval")

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await self.sendKeys(to: target, keys: "1", pressEnter: true)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await self.sendKeys(to: target, keys: "2", pressEnter: true)
    }

    /// Reject a tool with optional message
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        // First send 'n' + Enter to reject
        guard await self.sendKeys(to: target, keys: "n", pressEnter: true) else {
            return false
        }

        // If there's a message, send it after a brief delay
        if let message, !message.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            return await self.sendKeys(to: target, keys: message, pressEnter: true)
        }

        return true
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await self.sendKeys(to: target, keys: message, pressEnter: true)
    }

    // MARK: Private

    // MARK: - Private Methods

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments
        // Use -l flag to send keys literally (prevents interpreting special chars)
        let targetStr = target.targetString
        let textArgs = ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            // Send Enter as a separate command if needed
            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
