//
//  TerminalFocuser.swift
//  ClaudeIsland
//
//  Focuses the terminal app running a Claude session
//

import AppKit
import Foundation

/// Focuses the terminal app that contains a Claude session
struct TerminalFocuser {

    /// Focus the terminal app running the given Claude process
    /// Returns true if successful
    static func focusTerminal(forClaudePid pid: Int) -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Walk up process tree to find terminal
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let terminalInfo = tree[terminalPid] else {
            return false
        }

        // Find the running application by matching process name
        let terminalName = terminalInfo.command.components(separatedBy: "/").last ?? terminalInfo.command

        // Try to find and activate the app
        for app in NSWorkspace.shared.runningApplications {
            // Match by PID first (most accurate)
            if app.processIdentifier == Int32(terminalPid) {
                app.activate()
                return true
            }
        }

        // Fallback: match by name
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, name.lowercased().contains(terminalName.lowercased()) {
                app.activate()
                return true
            }
        }

        // Fallback: try known terminal bundle IDs
        let bundleIds = [
            "dev.warp.Warp-Stable",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.github.wez.wezterm"
        ]

        for bundleId in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                // Check if this app's PID is in our process tree's ancestor chain
                if isAncestor(appPid: Int(app.processIdentifier), ofProcess: pid, tree: tree) {
                    app.activate()
                    return true
                }
            }
        }

        return false
    }

    /// Focus terminal by working directory (fallback when no PID)
    static func focusTerminal(forWorkingDirectory cwd: String) -> Bool {
        // Try to find any terminal that might have this cwd
        // This is less reliable but better than nothing

        let bundleIds = [
            "dev.warp.Warp-Stable",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty"
        ]

        // Just activate the first running terminal we find
        for bundleId in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate()
                return true
            }
        }

        return false
    }

    /// Check if appPid is an ancestor of the given process
    private static func isAncestor(appPid: Int, ofProcess pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = pid
        var depth = 0

        while current > 1 && depth < 30 {
            if current == appPid {
                return true
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return false
    }
}
