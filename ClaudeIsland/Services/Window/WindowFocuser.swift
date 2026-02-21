//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai
//

import Foundation

/// Focuses windows using yabai
actor WindowFocuser {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = WindowFocuser()

    /// Focus a window by ID
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id),
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal
    func focusTmuxWindow(terminalPID: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPID: terminalPID, windows: windows) {
            return await self.focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPID: terminalPID, windows: windows) {
            return await self.focusWindow(id: window.id)
        }

        return false
    }
}
