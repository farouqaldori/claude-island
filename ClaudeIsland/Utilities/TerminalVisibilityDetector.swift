//
//  TerminalVisibilityDetector.swift
//  ClaudeIsland
//
//  Detects if terminal windows are visible on current space
//

import AppKit
import CoreGraphics
import OcclusionKit

struct TerminalVisibilityDetector {
    /// Check if the frontmost (active) application is a terminal
    static func isTerminalFrontmost() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmostApp.bundleIdentifier else {
            return false
        }

        return TerminalAppRegistry.isTerminalBundle(bundleId)
    }

    /// Check if a Claude session's terminal window is visible on the current space
    /// - Parameter sessionPid: The PID of the Claude process
    /// - Returns: true if the session's terminal has a visible, unobscured window on the current space
    static func isSessionTerminalVisible(sessionPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Get all on-screen windows using OcclusionKit
        guard let windows = try? OcclusionKit.allWindows() else {
            return false
        }

        // Find the terminal window for this session and check if it's visible
        for window in windows where window.isNormalLayer {
            let ownerPid = Int(window.processID)

            // Check if this window belongs to the session's terminal
            if ProcessTreeBuilder.shared.isDescendant(targetPid: sessionPid, ofAncestor: ownerPid, tree: tree) {
                // Found the terminal window - check if it's mostly visible using OcclusionKit
                // OcclusionKit uses accurate region subtraction (no overcounting)
                do {
                    let isOccluded = try await OcclusionKit.isOccluded(window.id, threshold: 0.5)
                    return !isOccluded
                } catch {
                    return false
                }
            }
        }

        return false
    }

    /// Check if a Claude session is currently focused (user is looking at it)
    /// - Parameter sessionPid: The PID of the Claude process
    /// - Returns: true if the session's terminal is frontmost and (for tmux) the pane is active
    static func isSessionFocused(sessionPid: Int) async -> Bool {
        // If no terminal is frontmost, session is definitely not focused
        guard isTerminalFrontmost() else {
            return false
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: sessionPid, tree: tree)

        if isInTmux {
            // For tmux sessions, check if the session's pane is active
            return await TmuxTargetFinder.shared.isSessionPaneActive(claudePid: sessionPid)
        } else {
            // For non-tmux sessions, check if the session is a descendant of the frontmost app
            // This handles terminal architectures where child processes (like iTermServer or Warp's
            // terminal-server) run the shell, but the main app process is what's reported as frontmost
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                return false
            }

            let frontmostPid = Int(frontmostApp.processIdentifier)
            return ProcessTreeBuilder.shared.isDescendant(targetPid: sessionPid, ofAncestor: frontmostPid, tree: tree)
        }
    }
}
