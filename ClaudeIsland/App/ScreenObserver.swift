//
//  ScreenObserver.swift
//  ClaudeIsland
//
//  Monitors screen configuration changes
//

import AppKit

/// Monitors screen configuration changes.
/// Isolated to MainActor (default) since notifications are observed on the main queue.
final class ScreenObserver {
    // MARK: Lifecycle

    init(onScreenChange: @escaping () -> Void) {
        self.onScreenChange = onScreenChange
        self.startObserving()
    }

    deinit {
        debounceTask?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Private

    /// nonisolated(unsafe) allows deinit cleanup — safe because deinit has exclusive access
    private nonisolated(unsafe) var observer: Any?
    private let onScreenChange: () -> Void
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval to coalesce rapid screen change notifications
    /// (e.g., when waking from sleep, displays reconnect in stages)
    private let debounceInterval: Duration = .milliseconds(500)

    private func startObserving() {
        self.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScreenChange()
            }
        }
    }

    private func scheduleScreenChange() {
        self.debounceTask?.cancel()

        self.debounceTask = Task(name: "screen-change-debounce") { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.onScreenChange()
        }
    }
}
