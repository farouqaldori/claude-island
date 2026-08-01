//
//  ToolApprovalHandler.swift
//  ClaudeIsland
//
//  Handles Claude tool approval operations via tmux
//

import Foundation
import os.log

/// Handles tool approval and rejection for Claude instances
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Approval")

    private init() {}

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "1", pressEnter: true)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "2", pressEnter: true)
    }

    /// Reject a tool with optional message
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        // First send 'n' + Enter to reject
        guard await sendKeys(to: target, keys: "n", pressEnter: true) else {
            return false
        }

        // If there's a message, send it after a brief delay
        if let message = message, !message.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            return await sendKeys(to: target, keys: message, pressEnter: true)
        }

        return true
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: message, pressEnter: true)
    }

    /// Answer an AskUserQuestion picker.
    ///
    /// The picker lists options as `1.`, `2.`, … and a bare digit selects and
    /// submits immediately. For multi-select questions each digit only toggles
    /// an option and leaves the cursor on the first row, so Return would toggle
    /// that row instead of submitting: the cursor has to walk down to the
    /// `Submit` row first. After the last question the picker shows a "Ready to
    /// submit your answers?" review screen that needs one more Return.
    func answerQuestion(
        optionNumbers: [Int],
        multiSelect: Bool,
        optionCount: Int,
        confirmReview: Bool,
        to target: TmuxTarget
    ) async -> Bool {
        guard !optionNumbers.isEmpty else { return false }

        NotchLog.write("answer", "target=\(target.targetString) picks=\(optionNumbers) multi=\(multiSelect) options=\(optionCount) confirmReview=\(confirmReview)")

        // A picker that isn't on screen means the keystrokes would land in a
        // shell — the single most likely way an answer silently disappears
        let before = await capturePane(target: target) ?? ""
        guard before.contains("to navigate") || before.contains("Enter to select") else {
            NotchLog.write("answer", "ABORT: no picker in pane \(target.targetString). tail=\(Self.tail(before))")
            return false
        }

        for number in optionNumbers {
            guard await sendKeys(to: target, keys: String(number), pressEnter: false) else {
                NotchLog.write("answer", "FAIL: send-keys \(number) failed")
                return false
            }
            if multiSelect {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        if multiSelect {
            // Rows below the options: "Type something", then "Submit"
            // ponytail: fixed step count — picker layout is stable across questions
            for _ in 0..<(optionCount + 1) {
                guard await sendKey(named: "Down", to: target) else { return false }
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard await sendKey(named: "Enter", to: target) else { return false }
        }

        // Only after the last question — polling during earlier ones would leave
        // two watchers racing to press Return on the same review screen
        if confirmReview {
            await confirmReviewIfPresent(target: target)
        }

        // The picker redraws on every accepted keystroke. An unchanged pane
        // means nothing was accepted, so report failure rather than let the UI
        // record an answer that never arrived.
        try? await Task.sleep(for: .milliseconds(250))
        let after = await capturePane(target: target) ?? ""
        guard after != before else {
            NotchLog.write("answer", "FAIL: pane unchanged after keys. tail=\(Self.tail(after))")
            return false
        }

        NotchLog.write("answer", "OK: pane advanced. tail=\(Self.tail(after))")
        return true
    }

    // MARK: - Private Methods

    /// Last few non-empty lines of a pane, for log context
    private static func tail(_ pane: String, lines: Int = 4) -> String {
        pane.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(lines)
            .joined(separator: " | ")
    }

    /// Confirm the final "Ready to submit your answers?" screen when it appears.
    /// The cursor already sits on "Submit answers", so Return is enough.
    private func confirmReviewIfPresent(target: TmuxTarget) async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(300))
            guard let pane = await capturePane(target: target) else { continue }
            if pane.contains("Ready to submit your answers?") {
                let sent = await sendKey(named: "Enter", to: target)
                NotchLog.write("answer", "review screen confirmed (enter sent=\(sent))")
                return
            }
        }
        NotchLog.write("answer", "no review screen appeared within 2.4s")
    }

    /// Current visible text of the target pane
    private func capturePane(target: TmuxTarget) async -> String? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }
        return try? await ProcessExecutor.shared.run(
            tmuxPath,
            arguments: ["capture-pane", "-t", target.targetString, "-p"]
        )
    }

    /// Send a named key (Down, Enter, …) rather than literal text
    private func sendKey(named key: String, to target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
        do {
            _ = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["send-keys", "-t", target.targetString, key]
            )
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments
        // Use -l flag to send keys literally (prevents interpreting special chars)
        let targetStr = target.targetString
        let textArgs = ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            // Send Enter as a separate command if needed
            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
