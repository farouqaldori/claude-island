//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Visual padding adjustments for hit test rect
/// These account for the gap between content size and visual bounds after
/// SwiftUI applies padding in NotchView.swift
private enum HitTestPadding {
    /// Width padding accounts for corner radius and horizontal content padding
    /// Applied in NotchView: .padding(.horizontal, 19) + .padding(.horizontal, 12)
    /// Total: 31pt per side, but adjusted to 52pt total for hit test accuracy
    static let width: CGFloat = 52

    /// Height padding accounts for bottom padding and corner radius
    /// Applied in NotchView: .padding(.bottom, 12) + corner radius (24)
    /// Extended to ensure bottom menu items are within hit test bounds
    static let height: CGFloat = 80
}

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Calculate the hit-test rect based on panel state
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                // Add padding to account for visual bounds (corner radius + content padding)
                let panelWidth = panelSize.width + HitTestPadding.width
                let panelHeight = panelSize.height + HitTestPadding.height
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                // When closed, use the notch rect
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                // Add some padding for easier interaction
                return CGRect(
                    x: (screenWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
