//
//  ClaudeAPIService.swift
//  ClaudeIsland
//
//  Service for fetching token usage data from Claude API
//

import Foundation
import os.log

// MARK: - APIUsageResponse

struct APIUsageResponse: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

// MARK: - UsageWindow

struct UsageWindow: Sendable {
    let utilization: Double
    let resetsAt: Date?
}

// MARK: - ClaudeAPIService

actor ClaudeAPIService {
    // MARK: Internal

    static let shared = ClaudeAPIService()

    func fetchUsage(sessionKey: String) async throws(APIServiceError) -> APIUsageResponse {
        let orgID = try await fetchOrganizationID(sessionKey: sessionKey)
        return try await self.fetchUsageData(sessionKey: sessionKey, orgID: orgID)
    }

    func fetchUsage(oauthToken: String) async throws(APIServiceError) -> APIUsageResponse {
        guard let url = URL(string: self.oauthUsageURL) else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw APIServiceError.cancelled
        } catch {
            throw APIServiceError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("OAuth usage request failed with status \(httpResponse.statusCode)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        return try self.parseUsageResponse(data)
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ClaudeAPIService")

    private let baseURL = "https://claude.ai/api"
    private let oauthUsageURL = "https://api.anthropic.com/api/oauth/usage"

    private func fetchOrganizationID(sessionKey: String) async throws(APIServiceError) -> String {
        guard let url = URL(string: "\(self.baseURL)/organizations") else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw APIServiceError.cancelled
        } catch {
            throw APIServiceError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        Self.logger.debug("Organizations response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("Organizations request failed with status \(httpResponse.statusCode)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Self.logger.error("Failed to parse organizations JSON")
            throw APIServiceError.parsingFailed
        }

        // Find organization with "chat" capability (Pro/Max subscription)
        // API-only orgs don't have usage data
        let chatOrg = json.first { org in
            if let capabilities = org["capabilities"] as? [String] {
                return capabilities.contains("chat")
            }
            return false
        }

        guard let selectedOrg = chatOrg ?? json.first,
              let uuid = selectedOrg["uuid"] as? String
        else {
            Self.logger.error("No valid organization found")
            throw APIServiceError.parsingFailed
        }

        Self.logger.debug("Selected organization: \(uuid, privacy: .private)")
        return uuid
    }

    private func fetchUsageData(sessionKey: String, orgID: String) async throws(APIServiceError) -> APIUsageResponse {
        Self.logger.debug("Fetching usage data for org: \(orgID, privacy: .private)")
        guard let url = URL(string: "\(self.baseURL)/organizations/\(orgID)/usage") else {
            throw APIServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw APIServiceError.cancelled
        } catch {
            throw APIServiceError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIServiceError.invalidResponse
        }

        Self.logger.debug("Usage response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            Self.logger.error("Usage request failed with status \(httpResponse.statusCode)")
            throw APIServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        return try self.parseUsageResponse(data)
    }

    private func parseUsageResponse(_ data: Data) throws(APIServiceError) -> APIUsageResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.error("Failed to parse JSON from usage response")
            throw APIServiceError.parsingFailed
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionPercentage = 0.0
        var sessionResetTime: Date?
        if let fiveHour = json["five_hour"] as? [String: Any] {
            sessionPercentage = self.parseUtilization(fiveHour["utilization"])
            if let resetsAt = fiveHour["resets_at"] as? String,
               let date = formatter.date(from: resetsAt) {
                sessionResetTime = date
            }
        }

        var weeklyPercentage = 0.0
        var weeklyResetTime: Date?
        if let sevenDay = json["seven_day"] as? [String: Any] {
            weeklyPercentage = self.parseUtilization(sevenDay["utilization"])
            if let resetsAt = sevenDay["resets_at"] as? String,
               let date = formatter.date(from: resetsAt) {
                weeklyResetTime = date
            }
        }

        Self.logger.debug("Parsed usage - session: \(sessionPercentage)%, weekly: \(weeklyPercentage)%")

        return APIUsageResponse(
            fiveHour: UsageWindow(utilization: sessionPercentage, resetsAt: sessionResetTime),
            sevenDay: UsageWindow(utilization: weeklyPercentage, resetsAt: weeklyResetTime),
        )
    }

    private func parseUtilization(_ value: Any?) -> Double {
        guard let value else { return 0 }

        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let stringValue = value as? String,
           let parsed = Double(stringValue.replacingOccurrences(of: "%", with: "")) {
            return parsed
        }
        return 0
    }
}

// MARK: - APIServiceError

enum APIServiceError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case parsingFailed
    case unauthorized
    case cancelled

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL"
        case .invalidResponse:
            "Invalid response from server"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case .parsingFailed:
            "Failed to parse response"
        case .unauthorized:
            "Unauthorized - session key may be expired"
        case .cancelled:
            "Request was cancelled"
        }
    }
}
