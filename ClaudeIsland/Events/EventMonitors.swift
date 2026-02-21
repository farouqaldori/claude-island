//
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors
//

import AppKit
import ApplicationServices

// MARK: - EventMonitors

/// Singleton that aggregates all event monitors.
/// MainActor (default) ensures thread-safe access to mutable state and AsyncStream continuations
/// since NSEvent monitors dispatch handlers on the main thread.
final class EventMonitors {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = EventMonitors()

    /// Current mouse location (synchronous access for direct reads)
    private(set) var currentMouseLocation: CGPoint = .zero

    /// Create a stream of mouse location updates (buffers newest only for throttling).
    /// Single-consumer: calling again finishes the previous stream.
    func makeMouseLocationStream() -> AsyncStream<CGPoint> {
        self.mouseLocationContinuation?.finish()

        let (stream, continuation) = AsyncStream.makeStream(of: CGPoint.self, bufferingPolicy: .bufferingNewest(1))
        self.mouseLocationContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task(name: "mouse-location-cleanup") { @MainActor [weak self] in
                self?.mouseLocationContinuation = nil
            }
        }
        return stream
    }

    /// Create a stream of mouse down events (yields Void — consumer reads NSEvent.mouseLocation directly).
    /// Single-consumer: calling again finishes the previous stream.
    func makeMouseDownStream() -> AsyncStream<Void> {
        self.mouseDownContinuation?.finish()

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.mouseDownContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task(name: "mouse-down-cleanup") { @MainActor [weak self] in
                self?.mouseDownContinuation = nil
            }
        }
        return stream
    }

    /// Start event monitors only if accessibility permission is already granted.
    /// Must be called after the user grants Accessibility permission (or on launch if already granted).
    /// Safe to call multiple times — subsequent calls are no-ops.
    func startMonitorsIfPermitted() {
        guard !self.monitorsStarted else { return }
        guard AXIsProcessTrusted() else { return }
        self.monitorsStarted = true
        self.setupMonitors()
    }

    // MARK: Private

    /// Continuation for mouse location stream
    private var mouseLocationContinuation: AsyncStream<CGPoint>.Continuation?

    /// Continuation for mouse down stream
    private var mouseDownContinuation: AsyncStream<Void>.Continuation?

    private var monitorsStarted = false
    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?

    private func setupMonitors() {
        // NSEvent monitor handlers are documented to run on the main thread.
        // Using MainActor.assumeIsolated is safe and avoids Swift 6 Sendable warnings
        // when passing NSEvent across isolation boundaries.
        self.mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                let location = NSEvent.mouseLocation
                self?.currentMouseLocation = location
                self?.mouseLocationContinuation?.yield(location)
            }
        }
        self.mouseMoveMonitor?.start()

        self.mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.mouseDownContinuation?.yield(())
            }
        }
        self.mouseDownMonitor?.start()

        self.mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                let location = NSEvent.mouseLocation
                self?.currentMouseLocation = location
                self?.mouseLocationContinuation?.yield(location)
            }
        }
        self.mouseDraggedMonitor?.start()
    }
}
