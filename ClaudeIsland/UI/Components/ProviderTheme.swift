import SwiftUI

struct ProviderTheme {
    let accent: Color
    let accentMuted: Color
    let gradientStart: Color
    let gradientEnd: Color
    let sectionBackground: Color
    let sectionBorder: Color
    let rowBackground: Color
    let rowHover: Color
    let badgeBackground: Color

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [gradientStart, gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension AgentProvider {
    var theme: ProviderTheme {
        switch self {
        case .claude:
            let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
            return ProviderTheme(
                accent: accent,
                accentMuted: accent.opacity(0.8),
                gradientStart: Color(red: 0.91, green: 0.57, blue: 0.42),
                gradientEnd: accent,
                sectionBackground: accent.opacity(0.08),
                sectionBorder: accent.opacity(0.35),
                rowBackground: accent.opacity(0.05),
                rowHover: accent.opacity(0.12),
                badgeBackground: accent.opacity(0.18)
            )
        case .codex:
            let accent = Color(red: 0.40, green: 0.52, blue: 0.98)
            return ProviderTheme(
                accent: accent,
                accentMuted: accent.opacity(0.85),
                gradientStart: Color(red: 0.64, green: 0.66, blue: 0.96),
                gradientEnd: Color(red: 0.23, green: 0.31, blue: 0.97),
                sectionBackground: accent.opacity(0.10),
                sectionBorder: accent.opacity(0.42),
                rowBackground: accent.opacity(0.06),
                rowHover: accent.opacity(0.14),
                badgeBackground: accent.opacity(0.20)
            )
        }
    }

    var approvalPositiveLabel: String {
        self == .codex ? "Approve" : "Allow"
    }

    var approvalNegativeLabel: String {
        self == .codex ? "Reject" : "Deny"
    }
}
