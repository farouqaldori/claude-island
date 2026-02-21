//
//  SessionPhaseHelpers.swift
//  ClaudeIsland
//
//  Helper functions for session phase display
//

import SwiftUI

enum SessionPhaseHelpers {
    /// Get color for session phase
    static func phaseColor(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval:
            TerminalColors.amber
        case .waitingForInput:
            TerminalColors.green
        case .processing:
            TerminalColors.cyan
        case .compacting:
            TerminalColors.magenta
        case .idle,
             .ended:
            TerminalColors.dim
        }
    }

    /// Get description for session phase
    static func phaseDescription(for phase: SessionPhase) -> String {
        switch phase {
        case let .waitingForApproval(ctx):
            "Waiting for approval: \(ctx.toolName)"
        case .waitingForInput:
            "Ready for input"
        case .processing:
            "Processing..."
        case .compacting:
            "Compacting context..."
        case .idle:
            "Idle"
        case .ended:
            "Ended"
        }
    }

    /// Format time ago string
    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
