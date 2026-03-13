//
//  YabaiController.swift
//  ClaudeIsland
//
//  High-level yabai window management controller
//

import Foundation

/// Controller for yabai window management
actor YabaiController {
    static let shared = YabaiController()

    private init() {}

    // MARK: - Public API

    /// Focus the terminal window for a given Claude PID
    func focusWindow(forClaudePid claudePid: Int) async -> Bool {
        guard await WindowFinder.shared.isYabaiAvailable() else {
            return false
        }

        let windows = await WindowFinder.shared.getAllWindows()
        let tree = ProcessTreeBuilder.shared.buildTree()

        return await focusTerminalForProcess(claudePid: claudePid, tree: tree, windows: windows)
    }

    /// Focus the terminal window for a given working directory
    func focusWindow(forWorkingDirectory workingDirectory: String) async -> Bool {
        guard await WindowFinder.shared.isYabaiAvailable() else { return false }

        let windows = await WindowFinder.shared.getAllWindows()
        let tree = ProcessTreeBuilder.shared.buildTree()

        return await focusTerminalForDirectory(workingDir: workingDirectory, tree: tree, windows: windows)
    }

    // MARK: - Private Implementation

    /// Find and focus the terminal window containing a Claude process
    private func focusTerminalForProcess(claudePid: Int, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        // Walk up the process tree to find the terminal app
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) else {
            return false
        }

        // Focus any window belonging to this terminal
        let terminalWindows = WindowFinder.shared.findWindows(forTerminalPid: terminalPid, windows: windows)
        if let window = terminalWindows.first {
            return await WindowFocuser.shared.focusWindow(id: window.id)
        }

        return false
    }

    /// Find and focus the terminal window for a working directory
    private func focusTerminalForDirectory(workingDir: String, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        let windowPids = Set(windows.map { $0.pid })

        // Find Claude processes with matching working directory
        for (pid, info) in tree {
            let isClaude = info.command.lowercased().contains("claude")
            guard isClaude else { continue }

            guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                  cwd == workingDir else { continue }

            // Found a Claude process with matching cwd - find its terminal
            guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
                  windowPids.contains(terminalPid) else { continue }

            let terminalWindows = WindowFinder.shared.findWindows(forTerminalPid: terminalPid, windows: windows)
            if let window = terminalWindows.first {
                return await WindowFocuser.shared.focusWindow(id: window.id)
            }
        }

        return false
    }
}
