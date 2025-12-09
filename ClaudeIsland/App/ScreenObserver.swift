//
//  ScreenObserver.swift
//  ClaudeIsland
//
//  Monitors screen configuration changes
//

import AppKit

class ScreenObserver {
    private var observer: Any?
    private let onScreenChange: () -> Void

    init(onScreenChange: @escaping () -> Void) {
        self.onScreenChange = onScreenChange
        startObserving()
    }

    deinit {
        stopObserving()
    }

    private func startObserving() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenChange()
        }
    }

    private func stopObserving() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
