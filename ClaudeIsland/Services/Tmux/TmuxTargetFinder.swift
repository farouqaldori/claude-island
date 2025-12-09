//
//  TmuxTargetFinder.swift
//  ClaudeIsland
//
//  Finds tmux targets for Claude processes
//

import Foundation

/// Finds tmux session/window/pane targets for Claude processes
actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    private init() {}

    /// Find the tmux target for a given Claude PID
    func findTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runTmuxCommand(tmuxPath: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
        ]) else {
            return nil
        }

        let tree = ProcessTreeBuilder.shared.buildTree()

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let panePid = Int(parts[1]) else { continue }

            let targetString = String(parts[0])

            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: panePid, tree: tree) {
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
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}"
        ]) else {
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

    // MARK: - Private Methods

    private func runTmuxCommand(tmuxPath: String, args: [String]) async -> String? {
        do {
            return try await ProcessExecutor.shared.run(tmuxPath, arguments: args)
        } catch {
            return nil
        }
    }
}
