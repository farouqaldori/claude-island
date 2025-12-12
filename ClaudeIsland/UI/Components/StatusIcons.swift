//
//  StatusIcons.swift
//  ClaudeIsland
//
//  Pixel-art status icons for Claude instances
//

import SwiftUI

// MARK: - Waiting for Input Icon (speech bubble)
struct WaitingForInputIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 12, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let dotSize = 4 * scale

            // Grid positions that are "on" (full opacity)
            let solidDots: [(CGFloat, CGFloat)] = [
                // Top row
                (3, 3), (7, 3), (11, 3), (15, 3), (19, 3), (23, 3), (27, 3),
                // Left edge
                (3, 7), (3, 11), (3, 15), (3, 19), (3, 23), (3, 27),
                // Right edge
                (27, 7), (27, 11), (27, 15), (27, 19),
                // Bottom left corner (speech tail)
                (7, 23),
                // Inner dots forming the pattern
                (11, 19), (15, 19), (19, 19), (23, 19),
            ]

            // Semi-transparent dots
            let fadedDots: [(CGFloat, CGFloat)] = [
                (7, 11), (7, 15), (7, 19),
                (11, 11), (11, 15),
                (15, 11), (15, 15),
                (19, 15),
            ]

            // Draw solid dots
            for (x, y) in solidDots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color))
            }

            // Draw faded dots
            for (x, y) in fadedDots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color.opacity(0.4)))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Waiting for Approval Icon (hand/stop)
struct WaitingForApprovalIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 12, color: Color = TerminalColors.amber) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let dotSize = 4 * scale

            // Grid positions that are "on" - forms a hand/approval shape
            let solidDots: [(CGFloat, CGFloat)] = [
                // Fingers at top
                (7, 7), (7, 11),
                (11, 3),
                (15, 3), (19, 3),
                (23, 7), (23, 11),
                // Palm/wrist
                (15, 19), (15, 27),
                (19, 15),
            ]

            for (x, y) in solidDots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Running/Processing Icon (hourglass) - Animated
struct RunningIcon: View {
    let size: CGFloat
    let color: Color
    @State private var rotation: Double = 0

    init(size: CGFloat = 12, color: Color = TerminalColors.cyan) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let dotSize = 4 * scale

            // Hourglass shape
            let solidDots: [(CGFloat, CGFloat)] = [
                // Top row
                (15, 3),
                // Upper part
                (7, 7), (15, 7), (23, 7),
                (15, 11), (15, 19),
                // Middle
                (3, 15), (7, 15), (11, 15), (19, 15), (23, 15), (27, 15),
                // Lower part
                (7, 23), (15, 23), (23, 23),
                (15, 27),
            ]

            let fadedDots: [(CGFloat, CGFloat)] = [
                (11, 11), (19, 11),
                (11, 19), (19, 19),
            ]

            // Draw solid dots
            for (x, y) in solidDots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color))
            }

            // Draw faded dots
            for (x, y) in fadedDots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color.opacity(0.4)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(
                .linear(duration: 2.0)
                .repeatForever(autoreverses: false)
            ) {
                rotation = 360
            }
        }
    }
}

// MARK: - Idle Icon (simple dash/dot)
struct IdleIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 12, color: Color = TerminalColors.dim) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let dotSize = 4 * scale

            // Simple horizontal line
            let dots: [(CGFloat, CGFloat)] = [
                (11, 15), (15, 15), (19, 15)
            ]

            for (x, y) in dots {
                let rect = CGRect(
                    x: x * scale - dotSize/2,
                    y: y * scale - dotSize/2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Completed Unseen Icon (checkmark)
struct CompletedUnseenIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 12, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Higher resolution grid (60x60) for smoother appearance, same visual size
    private let pixels: [(CGFloat, CGFloat)] = [
        // Short arm (left side going down-right)
        (8, 26),
        (12, 30),
        (16, 34),
        // Bottom turning point
        (20, 38),
        (24, 42),
        // Long arm (going up-right) - extended
        (28, 38),
        (32, 34),
        (36, 30),
        (40, 26),
        (44, 22),
        (48, 18),
        (52, 14),
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 60.0  // Higher resolution grid
            let pixelSize: CGFloat = 8 * scale  // Proportionally larger dots (same visual size as 4/30)

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Status Icon View (unified)
struct StatusIcon: View {
    let phase: SessionPhase
    let size: CGFloat

    init(phase: SessionPhase, size: CGFloat = 12) {
        self.phase = phase
        self.size = size
    }

    var body: some View {
        switch phase {
        case .waitingForInput:
            WaitingForInputIcon(size: size)
        case .waitingForApproval:
            WaitingForApprovalIcon(size: size)
        case .processing, .compacting:
            RunningIcon(size: size)
        case .idle, .ended:
            IdleIcon(size: size)
        }
    }
}
