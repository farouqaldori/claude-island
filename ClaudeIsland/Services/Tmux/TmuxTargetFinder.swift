//
//  TmuxTargetFinder.swift
//  ClaudeIsland
//
//  Finds tmux targets for Claude processes
//

import Foundation

/// Finds tmux session/window/pane targets for Claude processes
actor TmuxTargetFinder {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxTargetFinder()

    /// Find the tmux target for a given Claude PID
    func findTarget(forClaudePID claudePID: Int) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}",
        ])
        else {
            return nil
        }

        let tree = ProcessTreeBuilder.shared.buildTree()

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let panePID = Int(parts[1])
            else { continue }

            let targetString = String(parts[0])

            if ProcessTreeBuilder.shared.isDescendant(targetPID: claudePID, ofAncestor: panePID, tree: tree) {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    /// Find the tmux target for a given working directory
    func findTarget(forWorkingDirectory workingDir: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}",
        ])
        else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let targetString = String(parts[0])
            let panePath = String(parts[1])

            if panePath == workingDir {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    /// Check if a session's tmux pane is currently the active pane
    func isSessionPaneActive(claudePID: Int) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // Find which pane the Claude session is in
        guard let sessionTarget = await findTarget(forClaudePID: claudePID) else {
            return false
        }

        // Get the currently active pane
        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}",
        ])
        else {
            return false
        }

        let activeTarget = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTarget.targetString == activeTarget
    }

    // MARK: Private

    // MARK: - Private Methods

    private func runTmuxCommand(tmuxPath: String, args: [String]) async -> String? {
        do {
            return try await ProcessExecutor.shared.run(tmuxPath, arguments: args)
        } catch {
            return nil
        }
    }
}
