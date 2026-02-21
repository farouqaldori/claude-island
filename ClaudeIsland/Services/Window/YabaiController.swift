//
//  YabaiController.swift
//  ClaudeIsland
//
//  High-level yabai window management controller
//

import Foundation

/// Controller for yabai window management
actor YabaiController {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = YabaiController()

    // MARK: - Public API

    /// Focus the terminal window for a given Claude PID (tmux only)
    func focusWindow(forClaudePID claudePID: Int) async -> Bool {
        guard await WindowFinder.shared.isYabaiAvailable() else {
            return false
        }

        let windows = await WindowFinder.shared.getAllWindows()
        let tree = ProcessTreeBuilder.shared.buildTree()

        return await self.focusTmuxInstance(claudePID: claudePID, tree: tree, windows: windows)
    }

    /// Focus the terminal window for a given working directory (tmux only, fallback)
    func focusWindow(forWorkingDirectory workingDirectory: String) async -> Bool {
        guard await WindowFinder.shared.isYabaiAvailable() else { return false }

        return await self.focusWindow(forWorkingDir: workingDirectory)
    }

    // MARK: Private

    // MARK: - Private Implementation

    private func focusTmuxInstance(claudePID: Int, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        // Find the tmux target for this Claude process
        guard let target = await TmuxController.shared.findTmuxTarget(forClaudePID: claudePID) else {
            return false
        }

        // Switch to the correct pane
        _ = await TmuxController.shared.switchToPane(target: target)

        // Find terminal for this specific tmux session
        if let terminalPID = await findTmuxClientTerminal(forSession: target.session, tree: tree, windows: windows) {
            return await WindowFocuser.shared.focusTmuxWindow(terminalPID: terminalPID, windows: windows)
        }

        return false
    }

    private func focusWindow(forWorkingDir workingDir: String) async -> Bool {
        let windows = await WindowFinder.shared.getAllWindows()
        let tree = ProcessTreeBuilder.shared.buildTree()

        return await self.focusTmuxPane(forWorkingDir: workingDir, tree: tree, windows: windows)
    }

    // MARK: - Tmux Helpers

    private func findTmuxClientTerminal(forSession session: String, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Int? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }

        do {
            // Get clients attached to this specific session
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-clients", "-t", session, "-F", "#{client_pid}",
            ])

            let clientPIDs = output.components(separatedBy: "\n")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            let windowPIDs = Set(windows.map(\.pid))

            for clientPID in clientPIDs {
                var currentPID = clientPID
                while currentPID > 1 {
                    guard let info = tree[currentPID] else { break }
                    if self.isTerminalProcess(info.command) && windowPIDs.contains(currentPID) {
                        return currentPID
                    }
                    currentPID = info.ppid
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Check if command is a terminal (nonisolated helper to avoid MainActor access)
    private nonisolated func isTerminalProcess(_ command: String) -> Bool {
        let terminalCommands = ["Terminal", "iTerm", "iTerm2", "Alacritty", "kitty", "WezTerm", "wezterm-gui", "Hyper"]
        return terminalCommands.contains { command.contains($0) }
    }

    private func focusTmuxPane(forWorkingDir workingDir: String, tree: [Int: ProcessInfo], windows: [YabaiWindow]) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }

        do {
            let panesOutput = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}",
            ])

            let panes = panesOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

            for pane in panes {
                let parts = pane.components(separatedBy: "|")
                guard parts.count >= 2,
                      let panePID = Int(parts[1])
                else { continue }

                let targetString = parts[0]

                // Check if this pane has a Claude child with matching cwd
                for (pid, info) in tree {
                    let isChild = ProcessTreeBuilder.shared.isDescendant(targetPID: pid, ofAncestor: panePID, tree: tree)
                    let isClaude = info.command.lowercased().contains("claude")

                    guard isChild, isClaude else { continue }

                    guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPID: pid),
                          cwd == workingDir
                    else { continue }

                    // Found matching pane - switch to it
                    if let target = TmuxTarget(from: targetString) {
                        _ = await TmuxController.shared.switchToPane(target: target)

                        // Focus the terminal window for this session
                        if let terminalPID = await findTmuxClientTerminal(forSession: target.session, tree: tree, windows: windows) {
                            return await WindowFocuser.shared.focusTmuxWindow(terminalPID: terminalPID, windows: windows)
                        }
                    }
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }
}
