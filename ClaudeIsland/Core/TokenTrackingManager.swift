//
//  TokenTrackingManager.swift
//  ClaudeIsland
//
//  Central manager for token usage tracking
//

import Foundation
import os.log

// MARK: - UsageMetric

struct UsageMetric: Equatable, Sendable {
    static let zero = Self(used: 0, limit: 0, percentage: 0, resetTime: nil)

    let used: Int
    let limit: Int
    let percentage: Double
    let resetTime: Date?
}

// MARK: - TokenTrackingManager

@Observable
final class TokenTrackingManager {
    // MARK: Lifecycle

    private init() {
        self.migrateSessionKeyFromDefaults()
        self.startPeriodicRefresh()
    }

    // MARK: Internal

    static let shared = TokenTrackingManager()

    private(set) var sessionUsage: UsageMetric = .zero
    private(set) var weeklyUsage: UsageMetric = .zero
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    var sessionPercentage: Double {
        self.sessionUsage.percentage
    }

    var weeklyPercentage: Double {
        self.weeklyUsage.percentage
    }

    var sessionResetTime: Date? {
        self.sessionUsage.resetTime
    }

    var weeklyResetTime: Date? {
        self.weeklyUsage.resetTime
    }

    var isEnabled: Bool {
        AppSettings.tokenTrackingMode != .disabled
    }

    func refresh() async {
        Self.logger.debug("refresh() called, isEnabled: \(self.isEnabled), mode: \(String(describing: AppSettings.tokenTrackingMode))")

        guard self.isEnabled else {
            Self.logger.debug("Token tracking disabled, returning zero")
            self.sessionUsage = .zero
            self.weeklyUsage = .zero
            self.lastError = nil
            return
        }

        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do throws(TokenTrackingError) {
            switch AppSettings.tokenTrackingMode {
            case .disabled:
                self.sessionUsage = .zero
                self.weeklyUsage = .zero

            case .api:
                Self.logger.debug("Using API mode for refresh")
                try await self.refreshFromAPI()
            }
            self.lastError = nil
            Self.logger.debug("Refresh complete - session: \(self.sessionPercentage)%, weekly: \(self.weeklyPercentage)%")
        } catch {
            Self.logger.error("Token tracking refresh failed: \(error.errorDescription ?? "unknown", privacy: .public)")
            self.lastError = error.errorDescription
        }
    }

    func stopRefreshing() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
    }

    // MARK: - Keychain Helpers for Session Key

    @discardableResult
    func saveSessionKey(_ key: String?) -> Bool {
        let service = "com.engels74.ClaudeIsland"
        let account = "token-api-session-key"

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // If key is nil or empty, just delete
        guard let key, !key.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        let valueData = Data(key.utf8)

        // Try to update existing item first to avoid deleting before a successful write
        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        // errSecItemNotFound: item doesn't exist yet
        // errSecParam: existing item may have incompatible attributes (e.g. different kSecAttrAccessible)
        if updateStatus == errSecItemNotFound || updateStatus == errSecParam {
            if updateStatus == errSecParam {
                SecItemDelete(baseQuery as CFDictionary)
            }
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = valueData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            Self.logger.error("Failed to save session key to Keychain: \(addStatus)")
            return false
        }

        Self.logger.error("Failed to update session key in Keychain: \(updateStatus)")
        return false
    }

    func loadSessionKey() -> String? {
        let service = "com.engels74.ClaudeIsland"
        let account = "token-api-session-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }

        return key
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "TokenTrackingManager")

    private static let cliKeychainCooldownInterval: TimeInterval = 300
    private static let cliOAuthCacheAccount = "cli-oauth-cache"

    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?
    private var lastCLIKeychainAttempt: Date?

    private func startPeriodicRefresh() {
        self.periodicRefreshTask?.cancel()
        self.periodicRefreshTask = Task(name: "token-refresh") { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()

                let interval: TimeInterval = 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Migrate session key from UserDefaults to Keychain (one-time migration)
    private func migrateSessionKeyFromDefaults() {
        // If Keychain already has a value, skip migration
        if self.loadSessionKey() != nil { return }

        // Check if UserDefaults has a value to migrate
        let defaults = UserDefaults.standard
        let legacyKey = "tokenApiSessionKey"
        if let existingKey = defaults.string(forKey: legacyKey), !existingKey.isEmpty {
            if self.saveSessionKey(existingKey) {
                defaults.removeObject(forKey: legacyKey)
                Self.logger.info("Migrated session key from UserDefaults to Keychain")
            } else {
                Self.logger.error("Failed to migrate session key to Keychain, keeping UserDefaults entry")
            }
        }
    }

    private func refreshFromAPI() async throws(TokenTrackingError) {
        Self.logger.debug("refreshFromAPI called")
        let apiService = ClaudeAPIService.shared

        if AppSettings.tokenUseCLIOAuth {
            Self.logger.debug("CLI OAuth mode enabled, checking for token...")
            if let oauthToken = self.getCLIOAuthToken() {
                Self.logger.debug("Found OAuth token, fetching usage...")
                do {
                    let response = try await apiService.fetchUsage(oauthToken: oauthToken)
                    self.updateFromAPIResponse(response)
                    return
                } catch {
                    // Only invalidate cache for authentication rejections — transient errors
                    // should not wipe a valid token and re-trigger keychain prompts
                    if let apiError = error as? APIServiceError,
                       case let .httpError(statusCode) = apiError,
                       statusCode == 401 || statusCode == 403 {
                        self.deleteCLIOAuthCache()
                    }
                    throw TokenTrackingError.apiError(error.errorDescription ?? "API request failed")
                }
            } else {
                Self.logger.debug("CLI OAuth enabled but no token found, falling back to session key")
            }
        }

        guard let sessionKey = self.loadSessionKey(), !sessionKey.isEmpty else {
            Self.logger.error("No session key configured")
            throw TokenTrackingError.noCredentials
        }

        do {
            let response = try await apiService.fetchUsage(sessionKey: sessionKey)
            self.updateFromAPIResponse(response)
        } catch {
            throw TokenTrackingError.apiError(error.errorDescription ?? "API request failed")
        }
    }

    private func updateFromAPIResponse(_ response: APIUsageResponse) {
        Self.logger.debug("Updating from API response - session: \(response.fiveHour.utilization)%, weekly: \(response.sevenDay.utilization)%")

        self.sessionUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.fiveHour.utilization,
            resetTime: response.fiveHour.resetsAt,
        )

        self.weeklyUsage = UsageMetric(
            used: 0,
            limit: 0,
            percentage: response.sevenDay.utilization,
            resetTime: response.sevenDay.resetsAt,
        )
    }
}

// MARK: - CLI OAuth Keychain Operations

extension TokenTrackingManager {
    /// Save CLI OAuth JSON blob to Claude Island's own keychain (never prompts).
    @discardableResult
    private func saveCLIOAuthCache(_ data: Data) -> Bool {
        let service = "com.engels74.ClaudeIsland"
        let account = Self.cliOAuthCacheAccount

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            Self.logger.debug("Updated CLI OAuth cache in Keychain")
            return true
        }

        // errSecItemNotFound: item doesn't exist yet
        // errSecParam: existing item may have incompatible attributes (e.g. different kSecAttrAccessible)
        if updateStatus == errSecItemNotFound || updateStatus == errSecParam {
            if updateStatus == errSecParam {
                SecItemDelete(baseQuery as CFDictionary)
            }
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                Self.logger.debug("Saved CLI OAuth cache to Keychain")
                return true
            }
            Self.logger.error("Failed to save CLI OAuth cache to Keychain: \(addStatus)")
            return false
        }

        Self.logger.error("Failed to update CLI OAuth cache in Keychain: \(updateStatus)")
        return false
    }

    /// Load cached CLI OAuth JSON blob (never prompts).
    private func loadCLIOAuthCache() -> Data? {
        let service = "com.engels74.ClaudeIsland"
        let account = Self.cliOAuthCacheAccount

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return data
    }

    /// Delete the cached CLI OAuth data.
    private func deleteCLIOAuthCache() {
        let service = "com.engels74.ClaudeIsland"
        let account = Self.cliOAuthCacheAccount

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            Self.logger.debug("Deleted CLI OAuth cache from Keychain")
        } else {
            Self.logger.error("Failed to delete CLI OAuth cache from Keychain: \(status)")
        }
    }

    private func getCLIOAuthToken() -> String? {
        // Step 1: Try cached data first (own keychain — never prompts)
        if let cachedData = self.loadCLIOAuthCache() {
            if let token = self.extractOAuthToken(from: cachedData) {
                Self.logger.debug("Using cached CLI OAuth token")
                return token
            }
            // Cache exists but token is expired or invalid — delete it
            Self.logger.debug("Cached CLI OAuth token expired or invalid, will re-read from CLI keychain")
            self.deleteCLIOAuthCache()
        }

        // Step 2: Rate-limit CLI keychain access to avoid repeated prompts
        if let lastAttempt = self.lastCLIKeychainAttempt,
           Date().timeIntervalSince(lastAttempt) < Self.cliKeychainCooldownInterval {
            Self.logger.debug("CLI keychain access rate-limited, skipping")
            return nil
        }
        self.lastCLIKeychainAttempt = Date()

        // Step 3: Read from CLI keychain (may prompt once)
        guard let data = self.findCLIKeychainData() else {
            Self.logger.error("CLI OAuth token not found in any Keychain entry")
            return nil
        }

        // Step 4: Cache the raw data for future use (own keychain — never prompts)
        self.saveCLIOAuthCache(data)

        // Step 5: Extract and return token
        return self.extractOAuthToken(from: data)
    }

    /// Parse CLI OAuth JSON data and return the access token if valid and not expired.
    private func extractOAuthToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.error("Failed to parse CLI OAuth Keychain data as JSON")
            return nil
        }

        let accessToken: String
        let expirySource: [String: Any]

        if let nested = json["claudeAiOauth"] as? [String: Any],
           let token = nested["accessToken"] as? String {
            accessToken = token
            expirySource = nested
        } else if let token = json["accessToken"] as? String {
            accessToken = token
            expirySource = json
        } else {
            Self.logger.error("No accessToken found in CLI OAuth Keychain data")
            return nil
        }

        if self.isOAuthTokenExpired(expirySource) {
            return nil
        }

        return accessToken
    }

    private func findCLIKeychainData() -> Data? {
        let candidates: [(service: String, account: String)] = [
            ("Claude Code-credentials", NSUserName()),
            ("claude-cli", "oauth-tokens"),
        ]

        for candidate in candidates {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecAttrAccount as String: candidate.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let data = result as? Data {
                Self.logger.debug("Found CLI credentials in Keychain (service: \(candidate.service, privacy: .public))")
                return data
            } else {
                Self.logger.debug("No credentials at service: \(candidate.service, privacy: .public) (status: \(status))")
            }
        }

        return nil
    }

    /// Returns `true` if the token is expired and should not be used.
    private func isOAuthTokenExpired(_ source: [String: Any]) -> Bool {
        if let ms = source["expiresAt"] as? Double {
            let expiry = Date(timeIntervalSince1970: ms / 1000)
            if expiry < Date() {
                Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                return true
            }
            Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
        } else if let ms = source["expiresAt"] as? Int {
            let expiry = Date(timeIntervalSince1970: Double(ms) / 1000)
            if expiry < Date() {
                Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                return true
            }
            Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
        } else if let str = source["expiresAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var expiry = formatter.date(from: str)
            if expiry == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiry = formatter.date(from: str)
            }
            if let expiry {
                if expiry < Date() {
                    Self.logger.warning("CLI OAuth token is expired (expiry: \(expiry))")
                    return true
                }
                Self.logger.debug("CLI OAuth token valid (expires: \(expiry))")
            } else {
                Self.logger.debug("Could not parse expiresAt string, assuming token is valid")
            }
        } else {
            Self.logger.debug("No expiresAt field found, assuming token is valid")
        }

        return false
    }
}

// MARK: - TokenTrackingError

enum TokenTrackingError: Error, LocalizedError, Sendable {
    case noCredentials
    case apiError(String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            "No API credentials configured"
        case let .apiError(message):
            message
        }
    }
}
