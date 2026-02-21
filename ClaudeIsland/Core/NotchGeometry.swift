//
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: self.screenRect.midX - self.deviceNotchRect.width / 2,
            y: self.screenRect.maxY - self.deviceNotchRect.height,
            width: self.deviceNotchRect.width,
            height: self.deviceNotchRect.height,
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Match the actual rendered panel size (tuned to match visual output)
        let width = size.width - 6
        let height = size.height - 30
        return CGRect(
            x: self.screenRect.midX - width / 2,
            y: self.screenRect.maxY - height,
            width: width,
            height: height,
        )
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    func isPointInNotch(_ point: CGPoint) -> Bool {
        self.notchScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        self.openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !self.openedScreenRect(for: size).contains(point)
    }
}
