//
//  NativeTerminalInputHandler.swift
//  ClaudeIsland
//
//  Sends input to Claude Code sessions running in native macOS terminals
//  (Terminal.app, iTerm2, and others) without requiring tmux.
//  Also handles focusing terminal windows across virtual desktops.
//

import AppKit
import Foundation
import os.log

/// Handles sending input to native terminal applications via AppleScript
/// and focusing terminal windows across virtual desktops.
actor NativeTerminalInputHandler {
    static let shared = NativeTerminalInputHandler()

    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "NativeTerminal")

    private init() {}

    /// Send a message to a Claude Code session by writing to its terminal
    func sendMessage(_ message: String, tty: String, pid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let terminalName = findTerminalAppName(forPid: pid, tree: tree)

        Self.logger.debug("Sending to terminal: \(terminalName ?? "unknown", privacy: .public) tty: \(tty, privacy: .public)")

        let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        switch terminalName?.lowercased() {
        case let name where name?.contains("iterm") == true:
            return await sendViaITerm2(message: message, tty: fullTty)
        case "terminal":
            return await sendViaTerminalApp(message: message, tty: fullTty)
        default:
            return await sendViaSystemEvents(message: message, pid: pid, tree: tree)
        }
    }

    // MARK: - iTerm2

    private func sendViaITerm2(message: String, tty: String) async -> Bool {
        let escapedMessage = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTty = tty.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escapedTty)" then
                            tell s to write text "\(escapedMessage)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not_found"
        """

        return await runAppleScript(script, label: "iTerm2")
    }

    // MARK: - Terminal.app

    private func sendViaTerminalApp(message: String, tty: String) async -> Bool {
        let escapedMessage = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTty = tty.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escapedTty)" then
                        set selected of t to true
                        set index of w to 1
                        do script "\(escapedMessage)" in t
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not_found"
        """

        return await runAppleScript(script, label: "Terminal.app")
    }

    // MARK: - Generic (System Events)

    private func sendViaSystemEvents(message: String, pid: Int, tree: [Int: ProcessInfo]) async -> Bool {
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            Self.logger.warning("Could not find terminal PID for process \(pid)")
            return false
        }

        guard let terminalInfo = tree[terminalPid] else {
            return false
        }

        let appName = URL(fileURLWithPath: terminalInfo.command).lastPathComponent

        let escapedMessage = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "\(appName)" to activate
        delay 0.2
        tell application "System Events"
            keystroke "\(escapedMessage)"
            keystroke return
        end tell
        """

        return await runAppleScript(script, label: "SystemEvents/\(appName)")
    }

    // MARK: - Focus Terminal

    /// Focus the terminal window where a Claude Code session is running.
    /// Works across virtual desktops using NSRunningApplication.activate().
    /// For iTerm2 and Terminal.app, also selects the correct tab/session by TTY.
    func focusTerminal(pid: Int, tty: String?) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            Self.logger.warning("Could not find terminal PID for process \(pid)")
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
            Self.logger.warning("Could not find NSRunningApplication for PID \(terminalPid)")
            return false
        }

        let activated = app.activate(options: [.activateAllWindows])
        if !activated {
            Self.logger.warning("Failed to activate terminal app PID \(terminalPid)")
        }

        if let tty = tty {
            let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            let terminalName = findTerminalAppName(forPid: pid, tree: tree)

            switch terminalName?.lowercased() {
            case let name where name?.contains("iterm") == true:
                await focusITerm2Session(tty: fullTty)
            case "terminal":
                await focusTerminalAppTab(tty: fullTty)
            default:
                break
            }
        }

        return activated
    }

    private func focusITerm2Session(tty: String) async {
        let escapedTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escapedTty)" then
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        _ = await runAppleScript(script, label: "iTerm2-focus")
    }

    private func focusTerminalAppTab(tty: String) async {
        let escapedTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escapedTty)" then
                        set selected of t to true
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = await runAppleScript(script, label: "Terminal.app-focus")
    }

    // MARK: - Helpers

    private func findTerminalAppName(forPid pid: Int, tree: [Int: ProcessInfo]) -> String? {
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let info = tree[terminalPid] else {
            return nil
        }
        return URL(fileURLWithPath: info.command).lastPathComponent
    }

    private func runAppleScript(_ script: String, label: String) async -> Bool {
        do {
            let result = await ProcessExecutor.shared.runWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", script]
            )
            switch result {
            case .success(let output):
                let trimmed = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "not_found" {
                    Self.logger.warning("[\(label, privacy: .public)] TTY not found in terminal sessions")
                    return false
                }
                Self.logger.debug("[\(label, privacy: .public)] Script executed successfully")
                return true
            case .failure(let error):
                Self.logger.error("[\(label, privacy: .public)] Script failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
