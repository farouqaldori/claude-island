//
//  AnthropicBridgeClient.swift
//  ClaudeIsland
//
//  HTTP client for the Anthropic bridge API (remote-control)
//  Enables sending messages to Claude sessions via the cloud API
//

import Foundation
import os.log

/// Errors from the bridge API
enum BridgeAPIError: Error, LocalizedError {
    case noCredentials
    case httpError(statusCode: Int, body: String?)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No OAuth credentials found"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body ?? "unknown")"
        case .invalidResponse:
            return "Invalid response from API"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

/// Registration info returned when creating a bridge
struct BridgeRegistration: Sendable {
    let bridgeId: String
    let environmentId: String
}

/// HTTP client for Anthropic's bridge/remote-control API
actor AnthropicBridgeClient {
    static let shared = AnthropicBridgeClient()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "Bridge")

    private let baseURL = "https://api.anthropic.com"
    private let betaHeader = "ccr-byoc-2025-07-29"
    private let apiVersion = "2023-06-01"
    private let session: URLSession

    private var cachedCredentials: KeychainCredentialReader.Credentials?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Credentials

    /// Load and cache OAuth credentials
    func loadCredentials() throws -> KeychainCredentialReader.Credentials {
        DebugFileLogger.log("loadCredentials called, hasCached=\(cachedCredentials != nil)")
        if let cached = cachedCredentials {
            DebugFileLogger.log("loadCredentials: using cached (token length=\(cached.accessToken.count), orgId=\(cached.organizationId ?? "nil"))")
            return cached
        }

        guard let creds = KeychainCredentialReader.readCredentials() else {
            DebugFileLogger.log("loadCredentials: KeychainCredentialReader returned nil, throwing noCredentials")
            throw BridgeAPIError.noCredentials
        }

        cachedCredentials = creds
        DebugFileLogger.log("loadCredentials: loaded from keychain (token length=\(creds.accessToken.count), orgId=\(creds.organizationId ?? "nil"))")
        return creds
    }

    /// Clear cached credentials (e.g., on auth failure)
    func clearCredentials() {
        cachedCredentials = nil
        DebugFileLogger.log("clearCredentials: cleared")
    }

    // MARK: - Bridge Lifecycle

    /// Register a new bridge environment
    func registerBridge(
        directory: String,
        machineName: String = "ClaudeIsland",
        branch: String? = nil,
        gitRepoUrl: String? = nil,
        maxSessions: Int = 1
    ) async throws -> BridgeRegistration {
        DebugFileLogger.log("registerBridge: dir=\(directory), machine=\(machineName)")
        let creds = try loadCredentials()

        var body: [String: Any] = [
            "machine_name": machineName,
            "directory": directory,
            "max_sessions": maxSessions,
            "metadata": ["worker_type": "claude-island"]
        ]
        if let branch = branch {
            body["branch"] = branch
        }
        if let url = gitRepoUrl {
            body["git_repo_url"] = url
        }

        let data = try await post(
            path: "/v1/environments/bridge",
            body: body,
            token: creds.accessToken,
            orgId: creds.organizationId
        )

        let responseStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        DebugFileLogger.log("registerBridge response: \(responseStr.prefix(500))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bridgeId = json["id"] as? String ?? json["bridge_id"] as? String,
              let envId = json["environment_id"] as? String ?? json["id"] as? String else {
            DebugFileLogger.log("registerBridge: failed to parse response")
            throw BridgeAPIError.invalidResponse
        }

        DebugFileLogger.log("registerBridge: success bridgeId=\(bridgeId), envId=\(envId)")
        return BridgeRegistration(bridgeId: bridgeId, environmentId: envId)
    }

    /// Unregister a bridge environment
    func unregisterBridge(bridgeId: String) async throws {
        let creds = try loadCredentials()
        _ = try await delete(
            path: "/v1/environments/bridge/\(bridgeId)",
            token: creds.accessToken,
            orgId: creds.organizationId
        )
        DebugFileLogger.log("unregisterBridge: success bridgeId=\(bridgeId)")
    }

    // MARK: - Session Events

    /// Send events to a session (e.g., user messages)
    func sendEvents(sessionId: String, events: [[String: Any]]) async throws {
        DebugFileLogger.log("sendEvents: sessionId=\(sessionId), eventCount=\(events.count)")
        let creds = try loadCredentials()

        let body: [String: Any] = ["events": events]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let bodyStr = String(data: bodyData, encoding: .utf8) ?? "<non-utf8>"
        DebugFileLogger.log("sendEvents: POST /v1/sessions/\(sessionId)/events body=\(bodyStr.prefix(500))")

        _ = try await post(
            path: "/v1/sessions/\(sessionId)/events",
            body: body,
            token: creds.accessToken,
            orgId: creds.organizationId
        )

        DebugFileLogger.log("sendEvents: SUCCESS")
    }

    /// Rename a session (PATCH title to cloud API)
    func renameSession(_ sessionId: String, title: String) async throws {
        DebugFileLogger.log("renameSession: sessionId=\(sessionId), title='\(title)'")
        let creds = try loadCredentials()

        try await patch(
            path: "/v1/sessions/\(sessionId)",
            body: ["title": title],
            token: creds.accessToken,
            orgId: creds.organizationId
        )

        DebugFileLogger.log("renameSession: SUCCESS")
    }

    /// Send a user message to a session
    func sendUserMessage(_ text: String, sessionId: String) async throws {
        DebugFileLogger.log("sendUserMessage: text='\(text.prefix(50))' sessionId=\(sessionId)")
        let event: [String: Any] = [
            "type": "user_message",
            "content": text
        ]
        try await sendEvents(sessionId: sessionId, events: [event])
        DebugFileLogger.log("sendUserMessage: SUCCESS")
    }

    /// Poll for session events
    func pollEvents(sessionId: String) async throws -> [[String: Any]] {
        let creds = try loadCredentials()

        let data = try await get(
            path: "/v1/sessions/\(sessionId)/events",
            token: creds.accessToken,
            orgId: creds.organizationId
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return []
        }

        return events
    }

    // MARK: - Work Management

    /// Poll for work items on a bridge environment
    func pollForWork(environmentId: String) async throws -> [String: Any]? {
        let creds = try loadCredentials()

        let data = try await get(
            path: "/v1/environments/\(environmentId)/work/poll",
            token: creds.accessToken,
            orgId: creds.organizationId
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            return nil
        }

        return json
    }

    /// Acknowledge a work item
    func ackWork(environmentId: String, workId: String) async throws {
        let creds = try loadCredentials()
        _ = try await post(
            path: "/v1/environments/\(environmentId)/work/\(workId)/ack",
            body: [:],
            token: creds.accessToken,
            orgId: creds.organizationId
        )
    }

    /// Send heartbeat for active work
    func heartbeat(environmentId: String, workId: String) async throws {
        let creds = try loadCredentials()
        _ = try await post(
            path: "/v1/environments/\(environmentId)/work/\(workId)/heartbeat",
            body: [:],
            token: creds.accessToken,
            orgId: creds.organizationId
        )
    }

    /// Stop active work
    func stopWork(environmentId: String, workId: String) async throws {
        let creds = try loadCredentials()
        _ = try await post(
            path: "/v1/environments/\(environmentId)/work/\(workId)/stop",
            body: [:],
            token: creds.accessToken,
            orgId: creds.organizationId
        )
    }

    // MARK: - HTTP Helpers

    private func buildRequest(
        method: String,
        path: String,
        token: String,
        orgId: String?,
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw BridgeAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")

        if let orgId = orgId {
            request.setValue(orgId, forHTTPHeaderField: "anthropic-organization")
        }

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    @discardableResult
    private func post(path: String, body: [String: Any], token: String, orgId: String?) async throws -> Data {
        DebugFileLogger.log("HTTP POST \(path)")
        let request = try buildRequest(method: "POST", path: path, token: token, orgId: orgId, body: body)
        return try await execute(request)
    }

    @discardableResult
    private func get(path: String, token: String, orgId: String?) async throws -> Data {
        DebugFileLogger.log("HTTP GET \(path)")
        let request = try buildRequest(method: "GET", path: path, token: token, orgId: orgId)
        return try await execute(request)
    }

    @discardableResult
    private func patch(path: String, body: [String: Any], token: String, orgId: String?) async throws -> Data {
        DebugFileLogger.log("HTTP PATCH \(path)")
        let request = try buildRequest(method: "PATCH", path: path, token: token, orgId: orgId, body: body)
        return try await execute(request)
    }

    @discardableResult
    private func delete(path: String, token: String, orgId: String?) async throws -> Data {
        DebugFileLogger.log("HTTP DELETE \(path)")
        let request = try buildRequest(method: "DELETE", path: path, token: token, orgId: orgId)
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        DebugFileLogger.log("execute: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DebugFileLogger.log("execute: NETWORK ERROR - \(error.localizedDescription)")
            throw BridgeAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            DebugFileLogger.log("execute: not an HTTPURLResponse")
            throw BridgeAPIError.invalidResponse
        }

        DebugFileLogger.log("execute: HTTP \(httpResponse.statusCode), responseSize=\(data.count)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            DebugFileLogger.log("execute: HTTP ERROR \(httpResponse.statusCode): \(body?.prefix(500) ?? "?")")
            throw BridgeAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        DebugFileLogger.log("execute: SUCCESS response=\(responseStr.prefix(300))")
        return data
    }
}
