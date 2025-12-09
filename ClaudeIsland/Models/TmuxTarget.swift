//
//  TmuxTarget.swift
//  ClaudeIsland
//
//  Data model for tmux session/window/pane targeting
//

import Foundation

/// Represents a tmux target (session:window.pane)
struct TmuxTarget: Sendable {
    let session: String
    let window: String
    let pane: String

    nonisolated var targetString: String {
        "\(session):\(window).\(pane)"
    }

    nonisolated init(session: String, window: String, pane: String) {
        self.session = session
        self.window = window
        self.pane = pane
    }

    /// Parse from tmux target string format "session:window.pane"
    nonisolated init?(from targetString: String) {
        let sessionSplit = targetString.split(separator: ":", maxSplits: 1)
        guard sessionSplit.count == 2 else { return nil }

        let session = String(sessionSplit[0])
        let windowPane = String(sessionSplit[1])

        let paneSplit = windowPane.split(separator: ".", maxSplits: 1)
        guard paneSplit.count == 2 else { return nil }

        self.session = session
        self.window = String(paneSplit[0])
        self.pane = String(paneSplit[1])
    }
}
