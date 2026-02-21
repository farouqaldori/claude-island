//
//  TerminalFocuser.swift
//  ClaudeIsland
//
//  Focuses terminal applications without requiring yabai
//

import AppKit
import Foundation
import os

// MARK: - TerminalFocuser

/// Focuses terminal applications using NSRunningApplication.activate()
/// This provides a universal terminal focus feature that works without yabai.
///
/// - Important: All focus methods are async to avoid blocking the main thread.
///   The underlying `ProcessTreeBuilder.buildTree()` calls `ProcessExecutor.runSync`
///   which has a precondition that it must not run on the main thread.
struct TerminalFocuser: Sendable {
    // MARK: Lifecycle

    private nonisolated init() {}

    // MARK: Internal

    nonisolated static let shared = Self()

    /// Focus the terminal app for a given Claude PID
    /// - Parameter claudePID: The process ID of the Claude instance
    /// - Returns: true if the terminal was successfully focused
    func focusTerminal(forClaudePID claudePID: Int) async -> Bool {
        // Run blocking process tree operations off the main thread via detached task
        let result: (terminalPID: Int, command: String)? = await Task.detached(name: "find-terminal-pid", priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()

            guard let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: claudePID, tree: tree),
                  let terminalInfo = tree[terminalPID]
            else {
                return nil
            }

            return (terminalPID, terminalInfo.command)
        }.value

        guard let result else {
            Self.logger.debug("No terminal found for Claude PID \(claudePID)")
            return false
        }

        return await MainActor.run {
            self.activateTerminal(terminalPID: result.terminalPID, command: result.command)
        }
    }

    /// Focus the terminal app for a given working directory (fallback when no PID)
    /// - Parameter workingDirectory: The current working directory to match
    /// - Returns: true if a terminal was successfully focused
    func focusTerminal(forWorkingDirectory workingDirectory: String) async -> Bool {
        // Run blocking process tree operations off the main thread via detached task
        let result: (terminalPID: Int, command: String)? = await Task.detached(name: "find-terminal-cwd", priority: .userInitiated) {
            let tree = ProcessTreeBuilder.shared.buildTree()

            // Find Claude processes with matching cwd
            for (pid, info) in tree {
                guard info.command.lowercased().contains("claude") else { continue }
                guard let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPID: pid) else { continue }
                guard cwd == workingDirectory else { continue }

                // Found a Claude with matching cwd, find its terminal
                if let terminalPID = ProcessTreeBuilder.shared.findTerminalPID(forProcess: pid, tree: tree),
                   let terminalInfo = tree[terminalPID] {
                    return (terminalPID, terminalInfo.command)
                }
            }

            return nil
        }.value

        guard let result else {
            Self.logger.debug("No terminal found for working directory \(workingDirectory)")
            return false
        }

        return await MainActor.run {
            self.activateTerminal(terminalPID: result.terminalPID, command: result.command)
        }
    }

    // MARK: Private

    /// Logger for terminal focus operations
    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "TerminalFocuser")

    /// Activate a terminal app by PID and command
    /// - Parameters:
    ///   - terminalPID: The terminal's process ID
    ///   - command: The terminal's command/process name
    /// - Returns: true if the terminal was activated
    private nonisolated func activateTerminal(terminalPID: Int, command: String) -> Bool {
        // Try to get the running app directly by PID
        if let app = NSRunningApplication(processIdentifier: pid_t(terminalPID)) {
            if app.activate() {
                Self.logger.debug("Activated terminal via PID: \(terminalPID)")
                return true
            }
        }

        // Fallback: find by bundle identifier matching command name
        if let app = self.findRunningTerminalApp(command: command) {
            if app.activate() {
                Self.logger.debug("Activated terminal via bundle ID for command: \(command)")
                return true
            }
        }

        Self.logger.debug("Failed to activate terminal PID \(terminalPID) with command \(command)")
        return false
    }

    /// Find a running terminal app by matching the command name to known bundle identifiers
    /// - Parameter command: The terminal process command/name
    /// - Returns: The NSRunningApplication if found
    private nonisolated func findRunningTerminalApp(command: String) -> NSRunningApplication? {
        let lowerCommand = command.lowercased()

        // Map common terminal names to bundle identifiers
        let bundleIDMapping: [(patterns: [String], bundleID: String)] = [
            (["terminal"], "com.apple.Terminal"),
            (["iterm"], "com.googlecode.iterm2"),
            (["ghostty"], "com.mitchellh.ghostty"),
            (["alacritty"], "org.alacritty"),
            (["kitty"], "net.kovidgoyal.kitty"),
            (["hyper"], "co.zeit.hyper"),
            (["warp"], "dev.warp.Warp-Stable"),
            (["wezterm"], "com.github.wez.wezterm"),
            // VS Code Insiders must come before generic "code" to avoid false matches
            (["code - insiders", "code-insiders"], "com.microsoft.VSCodeInsiders"),
            (["vscode", "code"], "com.microsoft.VSCode"),
            (["cursor"], "com.todesktop.230313mzl4w4u92"),
            (["windsurf"], "com.exafunction.windsurf"),
            (["zed"], "dev.zed.Zed"),
        ]

        for (patterns, bundleID) in bundleIDMapping where patterns.contains(where: { lowerCommand.contains($0) }) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }

        // Try all known terminal bundle IDs as last resort
        for bundleID in TerminalAppRegistry.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }

        return nil
    }
}
