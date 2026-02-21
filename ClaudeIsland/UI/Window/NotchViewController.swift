//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

// MARK: - PassThroughHostingView

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard self.hitTestRect().contains(point) else {
            return nil // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

// MARK: - NotchViewController

class NotchViewController: NSViewController {
    // MARK: Lifecycle

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override func loadView() {
        let hosting = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Calculate the hit-test rect based on panel state
        hosting.hitTestRect = { [weak self] () -> CGRect in
            guard let self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 52 // Account for corner radius padding
                let panelHeight = panelSize.height
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight,
                )
            case .closed,
                 .popping:
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                // Calculate expansion padding to account for session dots and activity indicators
                // Max expansion: 2 * (notchHeight - 12) + 20 + 18 (permission indicator)
                // Matches NotchView.expansionWidth logic: base 20 + optional 18 for permission indicator
                let expansionPadding = 2 * max(0, notchRect.height - 12) + 38
                let totalWidth = notchRect.width + expansionPadding
                return CGRect(
                    x: (screenWidth - totalWidth) / 2,
                    y: windowHeight - notchRect.height - 5,
                    width: totalWidth,
                    height: notchRect.height + 10,
                )
            }
        }

        self.hostingView = hosting
        view = hosting
    }

    // MARK: Private

    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>?

    private var unwrappedHostingView: PassThroughHostingView<NotchView> {
        guard let hostingView else {
            fatalError("hostingView accessed before loadView()")
        }
        return hostingView
    }
}
