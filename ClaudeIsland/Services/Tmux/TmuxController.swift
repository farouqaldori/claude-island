//
//  TmuxController.swift
//  ClaudeIsland
//
//  High-level tmux operations controller
//

import Foundation

/// Controller for tmux operations
actor TmuxController {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxController()

    func findTmuxTarget(forClaudePID pid: Int) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forClaudePID: pid)
    }

    func findTmuxTarget(forWorkingDirectory dir: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forWorkingDirectory: dir)
    }

    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }

    func approveOnce(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(target: target)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(target: target)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(target: target, message: message)
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-window", "-t", "\(target.session):\(target.window)",
            ])

            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-pane", "-t", target.targetString,
            ])

            return true
        } catch {
            return false
        }
    }
}
