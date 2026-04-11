//
//  UsageSettings.swift
//  ClaudeIsland
//
//  Manages usage display preferences and per-profile plan configuration.
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "UsageSettings")

@MainActor
class UsageSettings: ObservableObject {
    static let shared = UsageSettings()

    // MARK: - Published State

    @Published var profilePlans: [String: PlanType] = [:]
    @Published var displayConfig: UsageDisplayConfig = .defaults
    @Published var isPickerExpanded: Bool = false

    /// Weekly reset day (1=Sunday, 2=Monday, ..., 6=Friday, 7=Saturday) per profile
    /// Defaults to Friday (6) which is common for Anthropic's weekly reset
    @Published var weeklyResetDay: [String: Int] = [:]

    /// Weekly reset hour (0-23, in local time) per profile
    @Published var weeklyResetHour: [String: Int] = [:]

    // MARK: - Constants

    private let plansKey = "usageProfilePlans"
    private let displayConfigKey = "usageDisplayConfig"
    private let weeklyResetDayKey = "usageWeeklyResetDay"
    private let weeklyResetHourKey = "usageWeeklyResetHour"
    private let rowHeight: CGFloat = 32

    private init() {
        loadPreferences()
    }

    // MARK: - Public API

    /// Extra height needed when picker is expanded
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        let profileCount = max(profilePlans.count, 1)
        let planOptions = 4  // Pro, Max 5x, Max 20x, Team
        let toggleCount = 3  // showCost, showBurnRate, showSavings
        let totalRows = toggleCount + profileCount * planOptions
        let visibleRows = min(totalRows, 8)
        return CGFloat(visibleRows) * rowHeight + 16
    }

    /// Get the plan for a profile, auto-detecting if not set
    func getPlan(for profile: String) -> PlanType {
        if let plan = profilePlans[profile] {
            return plan
        }
        // Auto-detect and cache
        let detected = PlanDetector.detectPlan(profile: profile)
        profilePlans[profile] = detected
        savePreferences()
        logger.info("Auto-detected plan '\(detected.displayName, privacy: .public)' for profile '\(profile, privacy: .public)'")
        return detected
    }

    /// Set plan for a profile (manual override)
    func setPlan(_ plan: PlanType, for profile: String) {
        profilePlans[profile] = plan
        savePreferences()
    }

    /// Get the most recent weekly reset date for a profile
    func lastWeeklyReset(for profile: String) -> Date {
        let resetDay = weeklyResetDay[profile] ?? 6  // Default: Friday
        let resetHour = weeklyResetHour[profile] ?? 14  // Default: 2 PM

        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)
        let currentHour = calendar.component(.hour, from: now)

        // Calculate days since last reset day
        var daysSinceReset = (currentWeekday - resetDay + 7) % 7
        // If it's the reset day but before the reset hour, go back a full week
        if daysSinceReset == 0 && currentHour < resetHour {
            daysSinceReset = 7
        }

        guard let resetDate = calendar.date(byAdding: .day, value: -daysSinceReset, to: now) else { return now }
        return calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: resetDate) ?? now
    }

    /// Re-detect plans for all registered profiles
    func redetectPlans() {
        for profile in profilePlans.keys {
            let detected = PlanDetector.detectPlan(profile: profile)
            profilePlans[profile] = detected
        }
        savePreferences()
    }

    /// Update display config
    func updateDisplayConfig(_ config: UsageDisplayConfig) {
        displayConfig = config
        savePreferences()
    }

    // MARK: - Persistence

    private func loadPreferences() {
        // Load display config
        if let data = UserDefaults.standard.data(forKey: displayConfigKey),
           let config = try? JSONDecoder().decode(UsageDisplayConfig.self, from: data) {
            displayConfig = config
        }

        // Load profile plans
        if let data = UserDefaults.standard.data(forKey: plansKey),
           let plans = try? JSONDecoder().decode([String: PlanType].self, from: data) {
            profilePlans = plans
        }

        // Load weekly reset config
        if let data = UserDefaults.standard.data(forKey: weeklyResetDayKey),
           let days = try? JSONDecoder().decode([String: Int].self, from: data) {
            weeklyResetDay = days
        }
        if let data = UserDefaults.standard.data(forKey: weeklyResetHourKey),
           let hours = try? JSONDecoder().decode([String: Int].self, from: data) {
            weeklyResetHour = hours
        }
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(displayConfig) {
            UserDefaults.standard.set(data, forKey: displayConfigKey)
        }
        if let data = try? JSONEncoder().encode(profilePlans) {
            UserDefaults.standard.set(data, forKey: plansKey)
        }
        if let data = try? JSONEncoder().encode(weeklyResetDay) {
            UserDefaults.standard.set(data, forKey: weeklyResetDayKey)
        }
        if let data = try? JSONEncoder().encode(weeklyResetHour) {
            UserDefaults.standard.set(data, forKey: weeklyResetHourKey)
        }
    }
}
