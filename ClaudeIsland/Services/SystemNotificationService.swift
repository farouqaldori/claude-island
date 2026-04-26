//
//  SystemNotificationService.swift
//  ClaudeIsland
//
//  Sends macOS system notifications when Claude Code tasks complete
//

import Foundation
import UserNotifications

/// Manages system notifications for task completion events
actor SystemNotificationService {
    static let shared = SystemNotificationService()

    private var lastNotificationTime: Date?
    private let minNotificationInterval: TimeInterval = 3.0 // Minimum seconds between notifications

    private init() {}

    // MARK: - Authorization

    /// Request notification authorization from the user
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            print("Notification authorization granted: \(granted)")
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }

    /// Check if notifications are authorized
    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Sending Notifications

    /// Send a notification when a Claude task completes
    func sendTaskCompletionNotification(sessionTitle: String? = nil) async {
        print("=== sendTaskCompletionNotification called ===")

        // Check authorization
        let status = await checkAuthorizationStatus()
        print("Current authorization status: \(status.rawValue)")

        if status != .authorized && status != .provisional {
            print("Not authorized, requesting authorization...")
            let authorized = await requestAuthorization()
            print("Authorization result: \(authorized)")
            if !authorized {
                print("Notifications not authorized, skipping notification")
                return
            }
        }

        // Throttle notifications - don't send too frequently
        if let lastTime = lastNotificationTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            print("Time since last notification: \(elapsed)s")
            if elapsed < minNotificationInterval {
                print("Throttled, skipping")
                return
            }
        }
        lastNotificationTime = Date()

        // Create notification content with alert style
        let content = UNMutableNotificationContent()
        content.title = LocalizationManager.shared.localizedString(for: LString.taskComplete)
        content.body = sessionTitle ?? LocalizationManager.shared.localizedString(for: LString.claudeReadyForInput)
        content.sound = .defaultCritical  // Use more prominent sound
        content.categoryIdentifier = "TASK_COMPLETE"  // Set category identifier

        // Use notification sound from settings if configured
        if let soundName = AppSettings.notificationSound.soundName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(soundName).aiff"))
        }

        print("Notification title: \(content.title)")
        print("Notification body: \(content.body)")

        // Create trigger (immediate delivery)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        // Create request
        let requestId = "claude-task-complete-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: trigger)

        // Send notification
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Task completion notification sent successfully")
        } catch {
            print("❌ Failed to send notification: \(error)")
        }
    }

    /// Send a notification for permission request
    func sendPermissionRequestNotification(toolName: String) async {
        let status = await checkAuthorizationStatus()
        if status != .authorized && status != .provisional {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = LocalizationManager.shared.localizedString(for: LString.permissionRequired)
        content.body = "\(toolName) " + LocalizationManager.shared.localizedString(for: LString.needsYourApproval)
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let requestId = "claude-permission-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: trigger)

        try? await UNUserNotificationCenter.current().add(request)
        print("✅ Permission notification sent")
    }
}