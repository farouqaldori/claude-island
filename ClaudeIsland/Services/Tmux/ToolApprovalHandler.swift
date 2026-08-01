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
    /// Digit shortcuts only work in the plain picker — the side-by-side variant
    /// (options carrying a `preview`) ignores them, so an answer sent that way
    /// vanished silently. Both variants respond to arrow keys and Return, so the
    /// cursor is walked onto the wanted row instead, matched by its label.
    ///
    /// Return selects in a single-select question and toggles in a multi-select
    /// one, where the `Submit` row has to be reached before the set is sent.
    /// After the last question a "Ready to submit your answers?" review screen
    /// takes one more Return.
    func answerQuestion(
        optionNumbers: [Int],
        multiSelect: Bool,
        optionCount: Int,
        confirmReview: Bool,
        to target: TmuxTarget
    ) async -> Bool {
        guard !optionNumbers.isEmpty else { return false }

        NotchLog.write("answer", "target=\(target.targetString) picks=\(optionNumbers) multi=\(multiSelect) confirmReview=\(confirmReview)")

        // tmux copy mode swallows keys outright, so that one is always undone
        await leaveCopyMode(target: target)

        let before = await capturePane(target: target) ?? ""
        let pickerVisible = before.contains("to navigate") || before.contains("Enter to select")

        // Scrolling Claude Code's own view (mouse wheel) pushes the picker off
        // screen while the keys still reach it. Nothing sent over tmux scrolls
        // it back, so send the answer without reading the screen instead of
        // failing for a reason the user can't see from the notch.
        if !pickerVisible {
            guard before.contains("Jump to bottom") || before.contains("to scroll") else {
                NotchLog.write("answer", "ABORT: no picker in pane \(target.targetString). tail=\(Self.tail(before))")
                return false
            }
            NotchLog.write("answer", "picker scrolled out of view — sending blind")
            return await answerBlind(
                optionNumbers: optionNumbers,
                multiSelect: multiSelect,
                optionCount: optionCount,
                confirmReview: confirmReview,
                to: target
            )
        }

        for number in optionNumbers.sorted() {
            guard await moveCursor(target: target, matches: { Self.row($0, isNumber: number) }) else {
                NotchLog.write("answer", "FAIL: could not put cursor on option \(number)")
                return false
            }
            guard await sendKey(named: "Enter", to: target) else {
                NotchLog.write("answer", "FAIL: Enter failed on option \(number)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        if multiSelect {
            guard await moveCursor(target: target, matches: { $0.contains("Submit") }),
                  await sendKey(named: "Enter", to: target) else {
                NotchLog.write("answer", "FAIL: could not submit multi-select set")
                return false
            }
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

    /// Leave copy mode (scrollback) so the pane shows and accepts live input
    private func leaveCopyMode(target: TmuxTarget) async {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return }
        let inMode = try? await ProcessExecutor.shared.run(
            tmuxPath,
            arguments: ["display-message", "-p", "-t", target.targetString, "#{pane_in_mode}"]
        )
        guard inMode?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return }

        _ = try? await ProcessExecutor.shared.run(
            tmuxPath,
            arguments: ["send-keys", "-X", "-t", target.targetString, "cancel"]
        )
        try? await Task.sleep(for: .milliseconds(120))
        NotchLog.write("answer", "left copy mode in \(target.targetString) (pane was scrolled up)")
    }

    /// Answer without reading the screen, for a picker scrolled out of view.
    /// The cursor sits on the first row of a freshly opened question, so rows
    /// are counted from there. Success can't be confirmed, so this trusts the
    /// keys landed — the alternative is refusing to answer at all.
    private func answerBlind(
        optionNumbers: [Int],
        multiSelect: Bool,
        optionCount: Int,
        confirmReview: Bool,
        to target: TmuxTarget
    ) async -> Bool {
        var cursor = 1

        for number in optionNumbers.sorted() {
            for _ in 0..<max(0, number - cursor) {
                guard await sendKey(named: "Down", to: target) else { return false }
                try? await Task.sleep(for: .milliseconds(60))
            }
            cursor = number

            guard await sendKey(named: "Enter", to: target) else { return false }
            try? await Task.sleep(for: .milliseconds(120))

            // A single-select answer moves on to the next question, which
            // starts with the cursor back on its first row
            if !multiSelect { cursor = 1 }
        }

        if multiSelect {
            // Rows past the options: "Type something", then "Submit"
            for _ in 0..<max(0, optionCount + 2 - cursor) {
                guard await sendKey(named: "Down", to: target) else { return false }
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard await sendKey(named: "Enter", to: target) else { return false }
        }

        if confirmReview {
            try? await Task.sleep(for: .milliseconds(400))
            _ = await sendKey(named: "Enter", to: target)
        }

        NotchLog.write("answer", "blind send finished (unverified)")
        return true
    }

    /// Walk the cursor down until it sits on the row `matches` accepts.
    /// Long labels wrap onto a second line, so rows are matched by their
    /// leading number rather than their text.
    private func moveCursor(
        target: TmuxTarget,
        matches: @Sendable (String) -> Bool
    ) async -> Bool {
        let maxSteps = 24

        for step in 0...maxSteps {
            guard let pane = await capturePane(target: target) else { return false }
            if let cursorLine = Self.cursorLine(pane), matches(cursorLine) {
                return true
            }
            guard step < maxSteps else { break }
            guard await sendKey(named: "Down", to: target) else { return false }
            try? await Task.sleep(for: .milliseconds(60))
        }

        return false
    }

    /// The picker row the cursor is on. The prompt line also carries `❯`, so
    /// only rows that look like picker entries count.
    private static func cursorLine(_ pane: String) -> String? {
        pane.components(separatedBy: "\n").last { line in
            guard line.contains("❯") else { return false }
            let body = line.drop { $0 != "❯" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return body.first?.isNumber == true || body.hasPrefix("Submit")
        }
    }

    /// Whether a picker row is the numbered entry `number`
    private static func row(_ line: String, isNumber number: Int) -> Bool {
        let body = line.drop { $0 != "❯" }.dropFirst().trimmingCharacters(in: .whitespaces)
        return body.hasPrefix("\(number).")
    }

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
