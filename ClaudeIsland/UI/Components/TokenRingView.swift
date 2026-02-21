//
//  TokenRingView.swift
//  ClaudeIsland
//
//  Circular progress ring component for token usage display
//

import SwiftUI

struct TokenRingView: View {
    // MARK: Internal

    let percentage: Double
    let label: String
    let size: CGFloat
    let strokeWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(self.ringColor.opacity(0.2), lineWidth: self.strokeWidth)

            Circle()
                .trim(from: 0, to: min(self.percentage / 100, 1.0))
                .stroke(self.ringColor, style: StrokeStyle(lineWidth: self.strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(self.label)
                .font(.system(size: self.size * 0.35, weight: .bold, design: .rounded))
                .foregroundColor(self.ringColor)
        }
        .frame(width: self.size, height: self.size)
    }

    // MARK: Private

    private var ringColor: Color {
        switch self.percentage {
        case 0 ..< 50:
            TerminalColors.green
        case 50 ..< 80:
            TerminalColors.amber
        default:
            TerminalColors.red
        }
    }
}

#Preview("Token Ring - Low Usage") {
    HStack(spacing: 12) {
        TokenRingView(percentage: 25, label: "S", size: 28, strokeWidth: 3)
        TokenRingView(percentage: 15, label: "W", size: 28, strokeWidth: 3)
    }
    .padding()
    .background(.black)
}

#Preview("Token Ring - Medium Usage") {
    HStack(spacing: 12) {
        TokenRingView(percentage: 65, label: "S", size: 28, strokeWidth: 3)
        TokenRingView(percentage: 55, label: "W", size: 28, strokeWidth: 3)
    }
    .padding()
    .background(.black)
}

#Preview("Token Ring - High Usage") {
    HStack(spacing: 12) {
        TokenRingView(percentage: 92, label: "S", size: 28, strokeWidth: 3)
        TokenRingView(percentage: 85, label: "W", size: 28, strokeWidth: 3)
    }
    .padding()
    .background(.black)
}

#Preview("Token Ring - Minimized Size") {
    HStack(spacing: 6) {
        TokenRingView(percentage: 45, label: "S", size: 16, strokeWidth: 2)
        TokenRingView(percentage: 72, label: "W", size: 16, strokeWidth: 2)
    }
    .padding()
    .background(.black)
}
