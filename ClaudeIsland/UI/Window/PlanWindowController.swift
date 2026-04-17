//
//  PlanWindowController.swift
//  ClaudeIsland
//
//  Manages a standalone window for viewing plan markdown content.
//

import AppKit
import SwiftUI

final class PlanWindowController {
    static let shared = PlanWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var contentModel = PlanContentModel()

    private init() {}

    func show(content: String) {
        contentModel.content = content

        if let window, window.isVisible {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = PlanDetailView(model: contentModel)
        let hostingView = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.center()
        window.title = "Plan"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 400, height: 300)
        window.level = .floating

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onClose()
            }
        }

        self.window = window
    }

    func close() {
        window?.close()
    }

    private func onClose() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Observable model so the window content updates when plan changes
@Observable
final class PlanContentModel {
    var content: String = ""
}
