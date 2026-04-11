//
//  PlanDetector.swift
//  ClaudeIsland
//
//  Auto-detects Claude subscription plan from local config files and macOS Keychain.
//

import Foundation
import os.log
import Security

private let logger = Logger(subsystem: "com.claudeisland", category: "PlanDetector")

/// Detects the Claude subscription plan for a given profile
enum PlanDetector {

    // MARK: - Public API

    /// Detect plan type for a profile by reading its config directory
    static func detectPlan(configDir: String) -> PlanType {
        // Step 1: Read .claude.json for heuristics
        let heuristic = readConfigHeuristics(configDir: configDir)

        // Step 2: Check keychain for precise plan info
        let keychainPlans = readKeychainPlans()

        // Step 3: Match keychain entry to this profile's heuristic
        if let matched = matchKeychainToHeuristic(heuristic: heuristic, keychainPlans: keychainPlans) {
            logger.info("Detected plan '\(matched.displayName, privacy: .public)' for \(configDir, privacy: .public) via keychain")
            return matched
        }

        // Step 4: Fall back to heuristic-only detection
        let fallback = heuristic.inferredPlan
        logger.info("Inferred plan '\(fallback.displayName, privacy: .public)' for \(configDir, privacy: .public) via heuristics")
        return fallback
    }

    /// Detect plan for a profile name using conventional directory naming
    static func detectPlan(profile: String) -> PlanType {
        return detectPlan(configDir: UsageTracker.configDir(for: profile))
    }

    // MARK: - Config File Reading

    private struct ConfigHeuristic {
        let penguinModeOrgEnabled: Bool
        let organizationRole: String?
        let subscriptionType: String? // Not stored in .claude.json, but kept for future

        var inferredPlan: PlanType {
            if penguinModeOrgEnabled {
                return .max20x  // Can't distinguish 5x vs 20x from config alone; default to 20x
            }
            if organizationRole == "membership_admin" {
                return .team
            }
            return .pro
        }

        var isMaxPlan: Bool { penguinModeOrgEnabled }
        var isTeamPlan: Bool { organizationRole == "membership_admin" }
    }

    private static func readConfigHeuristics(configDir: String) -> ConfigHeuristic {
        let configPath = configDir + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ConfigHeuristic(penguinModeOrgEnabled: false, organizationRole: nil, subscriptionType: nil)
        }

        let penguinMode = json["penguinModeOrgEnabled"] as? Bool ?? false
        let account = json["oauthAccount"] as? [String: Any]
        let orgRole = account?["organizationRole"] as? String

        return ConfigHeuristic(
            penguinModeOrgEnabled: penguinMode,
            organizationRole: orgRole,
            subscriptionType: nil
        )
    }

    // MARK: - Keychain Reading

    private struct KeychainPlan {
        let subscriptionType: String
        let rateLimitTier: String?
    }

    /// Read all Claude Code credential entries from the keychain.
    /// Uses a two-pass approach: first finds matching service names (no credential data),
    /// then fetches data only for matched items.
    private static func readKeychainPlans() -> [KeychainPlan] {
        // Pass 1: Find services matching "Claude Code-credentials-*" (attributes only, no data)
        let findQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var findResult: AnyObject?
        let findStatus = SecItemCopyMatching(findQuery as CFDictionary, &findResult)

        guard findStatus == errSecSuccess,
              let items = findResult as? [[String: Any]] else {
            logger.debug("Keychain query returned no items or failed: \(findStatus)")
            return []
        }

        // Filter to Claude Code services
        let matchingServices = items.compactMap { item -> String? in
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix("Claude Code-credentials-") else { return nil }
            return service
        }

        // Pass 2: Fetch credential data only for matched services
        var plans: [KeychainPlan] = []

        for service in matchingServices {
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var dataResult: AnyObject?
            guard SecItemCopyMatching(dataQuery as CFDictionary, &dataResult) == errSecSuccess,
                  let data = dataResult as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let subType = oauth["subscriptionType"] as? String else {
                continue
            }

            let rateLimitTier = oauth["rateLimitTier"] as? String

            plans.append(KeychainPlan(
                subscriptionType: subType,
                rateLimitTier: rateLimitTier
            ))

            logger.debug("Found keychain plan: \(subType, privacy: .public) tier: \(rateLimitTier ?? "none", privacy: .public)")
        }

        return plans
    }

    /// Convert a keychain plan to a PlanType
    private static func keychainPlanToPlanType(_ plan: KeychainPlan) -> PlanType {
        switch plan.subscriptionType {
        case "max":
            if plan.rateLimitTier == "default_claude_max_5x" {
                return .max5x
            }
            return .max20x
        case "team":
            return .team
        case "enterprise":
            return .enterprise
        case "pro":
            return .pro
        default:
            return .pro
        }
    }

    /// Match a keychain entry to a profile's heuristic
    private static func matchKeychainToHeuristic(heuristic: ConfigHeuristic, keychainPlans: [KeychainPlan]) -> PlanType? {
        // If only one keychain entry, use it directly
        if keychainPlans.count == 1 {
            return keychainPlanToPlanType(keychainPlans[0])
        }

        // Multiple entries: match by subscription type category
        for plan in keychainPlans {
            let isMaxEntry = plan.subscriptionType == "max"
            let isTeamEntry = plan.subscriptionType == "team"

            if heuristic.isMaxPlan && isMaxEntry {
                return keychainPlanToPlanType(plan)
            }
            if heuristic.isTeamPlan && isTeamEntry {
                return keychainPlanToPlanType(plan)
            }
            if !heuristic.isMaxPlan && !heuristic.isTeamPlan && plan.subscriptionType == "pro" {
                return keychainPlanToPlanType(plan)
            }
        }

        return nil
    }
}
