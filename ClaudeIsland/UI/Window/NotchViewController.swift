//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

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
            let screenWidth = geometry.screenRect.width
            // Anchor X relative to the window (window starts at screenFrame.origin.x)
            let anchorInWindow = vm.anchorX - geometry.screenRect.origin.x

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                let panelHeight = panelSize.height
                // Clamp so panel stays on screen
                let halfPanel = panelWidth / 2
                let clampedAnchor = max(halfPanel + 10, min(anchorInWindow, screenWidth - halfPanel - 10))
                return CGRect(
                    x: clampedAnchor - halfPanel,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                // Small anchor rect at status item position
                let notchRect = geometry.deviceNotchRect
                return CGRect(
                    x: anchorInWindow - notchRect.width / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
