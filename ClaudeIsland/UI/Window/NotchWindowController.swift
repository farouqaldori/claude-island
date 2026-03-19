//
//  NotchWindowController.swift
//  ClaudeIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen) {
        self.screen = screen

        let screenFrame = screen.frame

        // Window positioned near the right side of the screen (or restored from user preference)
        let windowHeight: CGFloat = 750
        let windowWidth: CGFloat = 620
        let savedX = UserDefaults.standard.double(forKey: "ClaudeIsland.windowX")
        let windowX: CGFloat = savedX > 0 ? CGFloat(savedX) : screenFrame.maxX - windowWidth
        let windowFrame = NSRect(
            x: max(screenFrame.origin.x, min(windowX, screenFrame.maxX - windowWidth)),
            y: screenFrame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )

        // Small anchor rect centered in the window
        let anchorSize = CGSize(width: 30, height: 24)
        let deviceNotchRect = CGRect(
            x: (windowWidth - anchorSize.width) / 2,
            y: 0,
            width: anchorSize.width,
            height: anchorSize.height
        )

        // Create view model — use windowFrame as the "screen" rect so SwiftUI centers within the window
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: windowFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Accept mouse events when hovering over the pill OR when opened.
        // This lets clicks/drags work on the pill while passing through everywhere else.
        viewModel.$isHovering
            .combineLatest(viewModel.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] (hovering, status) in
                switch status {
                case .opened:
                    notchWindow?.ignoresMouseEvents = false
                    if viewModel?.openReason != .notification {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKey()
                    }
                case .closed, .popping:
                    // Accept events only when hovering over the pill
                    notchWindow?.ignoresMouseEvents = !hovering
                }
            }
            .store(in: &cancellables)

        // Start with ignoring mouse events
        notchWindow.ignoresMouseEvents = true

        // No boot animation for menubar mode — panel opens on status item click
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
