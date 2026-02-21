//
//  TokenRingsOverlay.swift
//  ClaudeIsland
//
//  Container for positioning token usage rings in the notch
//

import SwiftUI

struct TokenRingsOverlay: View {
    // MARK: Internal

    let sessionPercentage: Double
    let weeklyPercentage: Double
    let showSession: Bool
    let showWeekly: Bool
    let size: CGFloat
    var strokeWidth: CGFloat = 2
    var showResetTime = false
    var sessionResetTime: Date?

    var totalWidth: CGFloat {
        let ringCount = (self.showSession ? 1 : 0) + (self.showWeekly ? 1 : 0)
        guard ringCount > 0 else { return 0 }
        return CGFloat(ringCount) * self.size + CGFloat(ringCount - 1) * 4
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if self.showSession {
                    TokenRingView(
                        percentage: self.sessionPercentage,
                        label: "S",
                        size: self.size,
                        strokeWidth: self.strokeWidth,
                    )
                }
                if self.showWeekly {
                    TokenRingView(
                        percentage: self.weeklyPercentage,
                        label: "W",
                        size: self.size,
                        strokeWidth: self.strokeWidth,
                    )
                }
            }
            if self.showResetTime, let resetTime = self.sessionResetTime {
                Text(self.formatResetTime(resetTime))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: Private

    private func formatResetTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#Preview("Rings - Both") {
    TokenRingsOverlay(
        sessionPercentage: 45,
        weeklyPercentage: 72,
        showSession: true,
        showWeekly: true,
        size: 16,
    )
    .padding()
    .background(.black)
}

#Preview("Rings - Session Only") {
    TokenRingsOverlay(
        sessionPercentage: 25,
        weeklyPercentage: 0,
        showSession: true,
        showWeekly: false,
        size: 16,
    )
    .padding()
    .background(.black)
}

#Preview("Rings - Weekly Only") {
    TokenRingsOverlay(
        sessionPercentage: 0,
        weeklyPercentage: 88,
        showSession: false,
        showWeekly: true,
        size: 16,
    )
    .padding()
    .background(.black)
}
