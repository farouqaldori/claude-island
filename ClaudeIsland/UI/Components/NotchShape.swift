//
//  NotchShape.swift
//  ClaudeIsland
//
//  Accurate notch shape using quadratic curves
//

import SwiftUI

struct NotchShape: Shape {
    // MARK: Lifecycle

    init(
        topCornerRadius: CGFloat = 6,
        bottomCornerRadius: CGFloat = 14,
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    // MARK: Internal

    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(self.topCornerRadius, self.bottomCornerRadius)
        }
        set {
            self.topCornerRadius = newValue.first
            self.bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        self.addTopLeftCorner(to: &path, rect: rect)
        self.addLeftEdge(to: &path, rect: rect)
        self.addBottomLeftCorner(to: &path, rect: rect)
        self.addBottomEdge(to: &path, rect: rect)
        self.addBottomRightCorner(to: &path, rect: rect)
        self.addRightEdge(to: &path, rect: rect)
        self.addTopRightCorner(to: &path, rect: rect)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }

    // MARK: Private

    private func addTopLeftCorner(to path: inout Path, rect: CGRect) {
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + self.topCornerRadius, y: rect.minY + self.topCornerRadius),
            control: CGPoint(x: rect.minX + self.topCornerRadius, y: rect.minY),
        )
    }

    private func addLeftEdge(to path: inout Path, rect: CGRect) {
        path.addLine(to: CGPoint(x: rect.minX + self.topCornerRadius, y: rect.maxY - self.bottomCornerRadius))
    }

    private func addBottomLeftCorner(to path: inout Path, rect: CGRect) {
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + self.topCornerRadius + self.bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + self.topCornerRadius, y: rect.maxY),
        )
    }

    private func addBottomEdge(to path: inout Path, rect: CGRect) {
        path.addLine(to: CGPoint(x: rect.maxX - self.topCornerRadius - self.bottomCornerRadius, y: rect.maxY))
    }

    private func addBottomRightCorner(to path: inout Path, rect: CGRect) {
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - self.topCornerRadius, y: rect.maxY - self.bottomCornerRadius),
            control: CGPoint(x: rect.maxX - self.topCornerRadius, y: rect.maxY),
        )
    }

    private func addRightEdge(to path: inout Path, rect: CGRect) {
        path.addLine(to: CGPoint(x: rect.maxX - self.topCornerRadius, y: rect.minY + self.topCornerRadius))
    }

    private func addTopRightCorner(to path: inout Path, rect: CGRect) {
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - self.topCornerRadius, y: rect.minY),
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        // Closed state
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(.black)
            .frame(width: 200, height: 32)

        // Open state
        NotchShape(topCornerRadius: 19, bottomCornerRadius: 24)
            .fill(.black)
            .frame(width: 600, height: 200)
    }
    .padding(20)
    .background(Color.gray.opacity(0.3))
}
