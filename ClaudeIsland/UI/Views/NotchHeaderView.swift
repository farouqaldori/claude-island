//
//  NotchHeaderView.swift
//  ClaudeIsland
//
//  Header bar for the dynamic island
//

import SwiftUI

// MARK: - ClaudeCrabIcon

struct ClaudeCrabIcon: View {
    // MARK: Lifecycle

    init(size: CGFloat = 16, color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    // MARK: Internal

    let size: CGFloat
    let color: Color
    var animateLegs = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            Canvas { drawContext, canvasSize in
                let scale = self.size / 52.0 // Original viewBox height is 52
                let xOffset = (canvasSize.width - 66 * scale) / 2

                // Left antenna
                let leftAntenna = Path { path in
                    path.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                drawContext.fill(leftAntenna, with: .color(self.color))

                // Right antenna
                let rightAntenna = Path { path in
                    path.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                drawContext.fill(rightAntenna, with: .color(self.color))

                // Animated legs - alternating up/down pattern for walking effect
                // Legs stay attached to body (y=39), only height changes
                let baseLegHeight: CGFloat = 13

                // Use static arrays to avoid allocation per frame
                let legPhase = self.animateLegs
                    ? Int(context.date.timeIntervalSinceReferenceDate / 0.15) % 4
                    : 0
                let currentHeightOffsets = self.animateLegs
                    ? Self.legHeightOffsets[legPhase]
                    : Self.neutralOffsets

                for index in 0 ..< 4 {
                    let xPos = Self.baseLegPositions[index]
                    let heightOffset = currentHeightOffsets[index]
                    let legHeight = baseLegHeight + heightOffset
                    let leg = Path { path in
                        path.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                    }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                    drawContext.fill(leg, with: .color(self.color))
                }

                // Main body
                let body = Path { path in
                    path.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                drawContext.fill(body, with: .color(self.color))

                // Left eye
                let leftEye = Path { path in
                    path.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                drawContext.fill(leftEye, with: .color(.black))

                // Right eye
                let rightEye = Path { path in
                    path.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                drawContext.fill(rightEye, with: .color(.black))
            }
            .frame(width: self.size * (66.0 / 52.0), height: self.size)
        }
    }

    // MARK: Private

    // MARK: - Static Animation Data

    /// Base X positions for the 4 legs - static to avoid allocation per frame
    private static let baseLegPositions: [CGFloat] = [6, 18, 42, 54]

    /// Height offsets for each animation phase
    /// Phase 0: alternating, Phase 1: neutral, Phase 2: opposite, Phase 3: neutral
    private static let legHeightOffsets: [[CGFloat]] = [
        [3, -3, 3, -3],
        [0, 0, 0, 0],
        [-3, 3, -3, 3],
        [0, 0, 0, 0],
    ]

    /// Neutral height offsets (no animation)
    private static let neutralOffsets: [CGFloat] = [0, 0, 0, 0]
}

// MARK: - PermissionIndicatorIcon

/// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    // MARK: Lifecycle

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // MARK: Internal

    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let scale = self.size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in self.pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize,
                )
                context.fill(Path(rect), with: .color(self.color))
            }
        }
        .frame(width: self.size, height: self.size)
    }

    // MARK: Private

    /// Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11), // Left column
        (11, 3), // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15), // Right of center
        (23, 7), (23, 11), // Right column
    ]
}

// MARK: - ReadyForInputIndicatorIcon

/// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    // MARK: Lifecycle

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // MARK: Internal

    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let scale = self.size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in self.pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize,
                )
                context.fill(Path(rect), with: .color(self.color))
            }
        }
        .frame(width: self.size, height: self.size)
    }

    // MARK: Private

    /// Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15), // Start of checkmark
        (9, 19), // Down stroke
        (13, 23), // Bottom of checkmark
        (17, 19), // Up stroke begins
        (21, 15), // Up stroke
        (25, 11), // Up stroke
        (29, 7), // End of checkmark
    ]
}

// MARK: - AccessibilityWarningIcon

/// Pixel art warning icon for missing accessibility permission
struct AccessibilityWarningIcon: View {
    // MARK: Lifecycle

    init(size: CGFloat = 14, color: Color = TerminalColors.amber) {
        self.size = size
        self.color = color
    }

    // MARK: Internal

    let size: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let scale = self.size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in self.pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize,
                )
                context.fill(Path(rect), with: .color(self.color))
            }
        }
        .frame(width: self.size, height: self.size)
    }

    // MARK: Private

    /// Triangle warning shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        // Top point
        (15, 3),
        // Second row
        (13, 7), (17, 7),
        // Third row
        (11, 11), (15, 11), (19, 11),
        // Fourth row
        (9, 15), (15, 15), (21, 15),
        // Fifth row
        (7, 19), (15, 19), (23, 19),
        // Bottom row (base of triangle)
        (5, 23), (9, 23), (13, 23), (17, 23), (21, 23), (25, 23),
        // Exclamation mark (inside triangle)
        (15, 27),
    ]
}

// MARK: - SessionStateDots

/// Displays colored dots representing session states in minimized notch
struct SessionStateDots: View {
    // MARK: Internal

    /// Sizing constants (shared with NotchView for layout sync)
    static let dotSize: CGFloat = 6
    static let dotSpacing: CGFloat = 4
    static let maxDots = 8
    /// Approximate width for overflow text "+N" at 9pt font
    static let overflowTextWidth: CGFloat = 18

    let sessions: [SessionState]

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            let displaySessions = Array(sortedActiveSessions.prefix(Self.maxDots))
            let overflow = self.sortedActiveSessions.count - Self.maxDots

            ForEach(displaySessions) { session in
                Circle()
                    .fill(self.color(for: session.phase))
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    /// Calculate expected width for a given number of active sessions
    /// Used by NotchView to ensure spacer math stays in sync
    static func expectedWidth(for sessionCount: Int) -> CGFloat {
        guard sessionCount > 1 else { return 0 }

        let visibleDots = min(sessionCount, maxDots)
        // Each dot is dotSize, with dotSpacing between them
        let dotsWidth = CGFloat(visibleDots) * self.dotSize + CGFloat(visibleDots - 1) * self.dotSpacing
        // Add overflow text width if needed
        let overflowWidth = sessionCount > self.maxDots ? (self.dotSpacing + self.overflowTextWidth) : 0

        return dotsWidth + overflowWidth
    }

    // MARK: Private

    /// Filter to exclude ended sessions and sort by priority
    /// Idle sessions are included as they represent running Claude processes
    private var sortedActiveSessions: [SessionState] {
        self.sessions
            .filter { $0.phase != .ended }
            .sorted { self.priority(for: $0.phase) < self.priority(for: $1.phase) }
    }

    /// Lower number = higher priority (shows first/left)
    private func priority(for phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval: 0
        case .processing,
             .compacting: 1
        case .waitingForInput: 2
        case .idle,
             .ended: 3
        }
    }

    /// Color for each session phase
    private func color(for phase: SessionPhase) -> Color {
        switch phase {
        case .waitingForApproval:
            TerminalColors.blue
        case .processing,
             .compacting:
            TerminalColors.prompt
        case .waitingForInput:
            TerminalColors.green
        case .idle,
             .ended:
            Color.white.opacity(0.25)
        }
    }
}
