//
//  NotchActivityCoordinator.swift
//  ClaudeIsland
//
//  Coordinates live activities and expanding views for the notch
//

import Combine
import SwiftUI

// MARK: - Activity Types

/// Types of activities that can be shown in the notch
enum NotchActivityType: Equatable {
    case claude      // Claude is processing
    case none
}

// MARK: - Expanding Activity

/// An activity that expands the notch to the sides
struct ExpandingActivity: Equatable {
    var show: Bool = false
    var type: NotchActivityType = .none
    var value: CGFloat = 0

    static let empty = ExpandingActivity()
}

// MARK: - Coordinator

/// Coordinates notch activities and state
@MainActor
class NotchActivityCoordinator: ObservableObject {
    static let shared = NotchActivityCoordinator()

    // MARK: - Published State

    /// Current expanding activity (expands notch to sides)
    @Published var expandingActivity: ExpandingActivity = .empty {
        didSet {
            if expandingActivity.show {
                scheduleActivityHide()
            } else {
                activityTask?.cancel()
            }
        }
    }

    /// Duration before auto-hiding the activity
    var activityDuration: TimeInterval = 0 // 0 = manual control (won't auto-hide)

    // MARK: - Private

    private var activityTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Show an expanding activity
    func showActivity(
        type: NotchActivityType,
        value: CGFloat = 0,
        duration: TimeInterval = 0
    ) {
        activityDuration = duration

        withAnimation(.smooth) {
            expandingActivity = ExpandingActivity(
                show: true,
                type: type,
                value: value
            )
        }
    }

    /// Hide the current activity
    func hideActivity() {
        withAnimation(.smooth) {
            expandingActivity = .empty
        }
    }

    /// Toggle activity visibility
    func toggleActivity(type: NotchActivityType, value: CGFloat = 0) {
        if expandingActivity.show && expandingActivity.type == type {
            hideActivity()
        } else {
            showActivity(type: type, value: value)
        }
    }

    // MARK: - Private

    private func scheduleActivityHide() {
        activityTask?.cancel()

        // Duration of 0 means manual control - don't auto-hide
        guard activityDuration > 0 else { return }

        let currentType = expandingActivity.type
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.activityDuration ?? 3))
            guard let self = self, !Task.isCancelled else { return }

            // Only hide if still showing the same type
            if self.expandingActivity.type == currentType {
                self.hideActivity()
            }
        }
    }
}
