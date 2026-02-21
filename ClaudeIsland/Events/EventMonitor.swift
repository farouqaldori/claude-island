//
//  EventMonitor.swift
//  ClaudeIsland
//
//  Wraps NSEvent monitoring for safe lifecycle management
//

import AppKit

/// Wraps NSEvent monitoring with proper lifecycle management.
/// Isolated to MainActor (default) since NSEvent monitors deliver on the main thread.
final class EventMonitor {
    // MARK: Lifecycle

    init(mask: NSEvent.EventTypeMask, handler: @escaping @Sendable (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: Internal

    /// Start monitoring events.
    func start() {
        // Global monitor for events outside our app
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: self.mask) { [weak self] event in
            self?.handler(event)
        }

        // Local monitor for events inside our app
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: self.mask) { [weak self] event in
            self?.handler(event)
            return event
        }
    }

    /// Stop monitoring events.
    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }
    }

    // MARK: Private

    /// nonisolated(unsafe) allows deinit cleanup — safe because deinit has exclusive access
    private nonisolated(unsafe) var globalMonitor: Any?
    private nonisolated(unsafe) var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: @Sendable (NSEvent) -> Void
}
