//
//  NotchActivityCoordinator.swift
//  ClaudeIsland
//
//  Coordinates live activities and expanding views for the notch
//

import Observation
import SwiftUI

// MARK: - NotchActivityType

/// Types of activities that can be shown in the notch
enum NotchActivityType: Equatable {
    case claude // Claude is processing
    case none
}

// MARK: - ExpandingActivity

/// An activity that expands the notch to the sides
struct ExpandingActivity: Equatable {
    static let empty = Self()

    var show = false
    var type: NotchActivityType = .none
    var value: CGFloat = 0
}

// MARK: - NotchActivityCoordinator

/// Coordinates notch activities and state
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
final class NotchActivityCoordinator {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = NotchActivityCoordinator()

    /// Duration before auto-hiding the activity
    var activityDuration: TimeInterval = 0 // 0 = manual control (won't auto-hide)

    // MARK: - Observable State

    /// Current expanding activity (expands notch to sides)
    var expandingActivity: ExpandingActivity = .empty {
        didSet {
            if self.expandingActivity.show {
                self.scheduleActivityHide()
            } else {
                self.activityTask?.cancel()
            }
        }
    }

    // MARK: - Public API

    /// Show an expanding activity
    func showActivity(
        type: NotchActivityType,
        value: CGFloat = 0,
        duration: TimeInterval = 0,
    ) {
        self.activityDuration = duration

        withAnimation(.smooth) {
            self.expandingActivity = ExpandingActivity(
                show: true,
                type: type,
                value: value,
            )
        }
    }

    /// Hide the current activity
    func hideActivity() {
        withAnimation(.smooth) {
            self.expandingActivity = .empty
        }
    }

    /// Toggle activity visibility
    func toggleActivity(type: NotchActivityType, value: CGFloat = 0) {
        if self.expandingActivity.show && self.expandingActivity.type == type {
            self.hideActivity()
        } else {
            self.showActivity(type: type, value: value)
        }
    }

    // MARK: Private

    private var activityTask: Task<Void, Never>?

    private func scheduleActivityHide() {
        self.activityTask?.cancel()

        // Duration of 0 means manual control - don't auto-hide
        guard self.activityDuration > 0 else { return }

        let currentType = self.expandingActivity.type
        self.activityTask = Task(name: "activity-auto-hide") { [weak self] in
            try? await Task.sleep(for: .seconds(self?.activityDuration ?? 3))
            guard let self, !Task.isCancelled else { return }

            // Only hide if still showing the same type
            if self.expandingActivity.type == currentType {
                self.hideActivity()
            }
        }
    }
}
