//
//  RemoteSessionScanner.swift
//  ClaudeIsland
//
//  Polls GET /v1/sessions to discover active remote-control sessions
//  across all machines on the user's account.
//

import Foundation
import os.log

/// Discovers active Claude Code remote sessions via the Anthropic API
actor RemoteSessionScanner {
    static let shared = RemoteSessionScanner()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "RemoteScanner")

    /// How often to poll session list (seconds)
    private let pollInterval: TimeInterval = 15

    /// How often to poll events for active sessions (seconds)
    private let eventPollInterval: TimeInterval = 5

    /// Currently running poll task
    private var pollTask: Task<Void, Never>?

    /// Currently running event poll task
    private var eventPollTask: Task<Void, Never>?

    /// Cloud session IDs that are currently "running" (need event polling)
    private var activeCloudSessionIds: Set<String> = []

    private init() {}

    /// Info about a discovered remote session
    struct DiscoveredSession: Sendable {
        let cloudSessionId: String      // e.g. "session_01XWLZ1jKfi4rQ1WTPYsJHds"
        let environmentId: String       // e.g. "env_01Myyd5XsJmTkxZagyrie41u"
        let title: String               // e.g. "Interactive session"
        let status: String              // "running", "idle"
        let repoName: String?           // e.g. "fox" (from git source URL)
        let model: String?              // e.g. "claude-opus-4-6"
        let updatedAt: Date?
        let createdAt: Date?
    }

    // MARK: - Polling Lifecycle

    /// Start periodic polling
    func startPolling(onDiscovery: @escaping @Sendable ([DiscoveredSession]) -> Void) {
        stopPolling()
        pollTask = Task { [weak self] in
            // Initial poll immediately
            if let sessions = await self?.fetchSessions() {
                onDiscovery(sessions)
                await self?.updateActiveSessionIds(sessions)
            }

            // Then poll periodically
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 15))
                guard !Task.isCancelled else { break }
                if let sessions = await self?.fetchSessions() {
                    onDiscovery(sessions)
                    await self?.updateActiveSessionIds(sessions)
                }
            }
        }

        // Start a faster event poll loop for active sessions
        eventPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.eventPollInterval ?? 5))
                guard !Task.isCancelled else { break }
                await self?.pollActiveSessionEvents()
            }
        }
    }

    /// Stop polling
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        eventPollTask?.cancel()
        eventPollTask = nil
        activeCloudSessionIds.removeAll()
    }

    // MARK: - Active Session Event Polling

    /// Update which sessions need event polling (all non-archived sessions)
    private func updateActiveSessionIds(_ sessions: [DiscoveredSession]) {
        activeCloudSessionIds = Set(sessions.map(\.cloudSessionId))
    }

    /// Poll events for all active (running) sessions and push updates to SessionStore
    private func pollActiveSessionEvents() async {
        let sessionIds = activeCloudSessionIds
        guard !sessionIds.isEmpty else { return }

        for cloudSessionId in sessionIds {
            guard !Task.isCancelled else { break }
            let events = await loadEvents(cloudSessionId: cloudSessionId)
            if !events.isEmpty {
                let sessionId = "remote-\(cloudSessionId)"
                Task {
                    await SessionStore.shared.process(.remoteHistoryLoaded(sessionId: sessionId, events: events))
                }
            }
        }
    }

    // MARK: - History Loading

    /// Load conversation events for a remote session
    func loadEvents(cloudSessionId: String) async -> [RemoteEvent] {
        do {
            let creds = try await AnthropicBridgeClient.shared.loadCredentials()

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/sessions/\(cloudSessionId)/events")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
            if let orgId = creds.organizationId {
                request.setValue(orgId, forHTTPHeaderField: "anthropic-organization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventsArray = json["data"] as? [[String: Any]] else {
                return []
            }

            return parseEvents(eventsArray)
        } catch {
            Self.logger.error("Failed to load events: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - API Call

    /// Fetch active sessions from the Anthropic API
    private func fetchSessions() async -> [DiscoveredSession]? {
        do {
            let creds = try await AnthropicBridgeClient.shared.loadCredentials()

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/sessions")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
            if let orgId = creds.organizationId {
                request.setValue(orgId, forHTTPHeaderField: "anthropic-organization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionsArray = json["data"] as? [[String: Any]] else {
                return nil
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var discovered: [DiscoveredSession] = []

            for sessionJson in sessionsArray {
                guard let id = sessionJson["id"] as? String,
                      let envId = sessionJson["environment_id"] as? String,
                      let status = sessionJson["session_status"] as? String else {
                    continue
                }

                // Skip archived sessions
                guard status != "archived" else { continue }

                // Only show sessions updated today (stale "running" sessions
                // from days ago are CLI processes that never cleaned up)
                if let updatedStr = sessionJson["updated_at"] as? String,
                   let updatedDate = dateFormatter.date(from: updatedStr) {
                    let calendar = Calendar.current
                    guard calendar.isDateInToday(updatedDate) else { continue }
                }

                let title = sessionJson["title"] as? String ?? "Untitled"

                // Extract repo name from sources
                var repoName: String?
                if let context = sessionJson["session_context"] as? [String: Any],
                   let sources = context["sources"] as? [[String: Any]] {
                    for source in sources {
                        if let url = source["url"] as? String {
                            repoName = URL(string: url)?.lastPathComponent
                            break
                        }
                    }
                }

                // Extract model
                var model: String?
                if let context = sessionJson["session_context"] as? [String: Any] {
                    model = context["model"] as? String
                }

                // Parse dates
                var updatedAt: Date?
                if let updatedStr = sessionJson["updated_at"] as? String {
                    updatedAt = dateFormatter.date(from: updatedStr)
                }
                var createdAt: Date?
                if let createdStr = sessionJson["created_at"] as? String {
                    createdAt = dateFormatter.date(from: createdStr)
                }

                discovered.append(DiscoveredSession(
                    cloudSessionId: id,
                    environmentId: envId,
                    title: title,
                    status: status,
                    repoName: repoName,
                    model: model,
                    updatedAt: updatedAt,
                    createdAt: createdAt
                ))
            }

            return discovered

        } catch {
            Self.logger.error("Failed to fetch remote sessions: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Event Parsing

    /// Parsed remote event for chat history
    struct RemoteEvent: Sendable {
        enum EventType: Sendable {
            case user(String)
            case assistant(String)
            case toolUse(name: String, input: [String: String])
            case toolResult(toolUseId: String, content: String)
        }

        let id: String
        let type: EventType
        let timestamp: Date
    }

    private func parseEvents(_ eventsArray: [[String: Any]]) -> [RemoteEvent] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var events: [RemoteEvent] = []

        for eventJson in eventsArray {
            let eventType = eventJson["type"] as? String ?? ""
            let uuid = eventJson["uuid"] as? String ?? UUID().uuidString
            let timestamp: Date
            if let dateStr = eventJson["created_at"] as? String {
                timestamp = dateFormatter.date(from: dateStr) ?? Date()
            } else {
                timestamp = Date()
            }

            guard let message = eventJson["message"] as? [String: Any] else { continue }

            switch eventType {
            case "user":
                if let content = message["content"] as? String {
                    events.append(RemoteEvent(id: uuid, type: .user(content), timestamp: timestamp))
                }

            case "assistant":
                let content = message["content"]
                if let blocks = content as? [[String: Any]] {
                    // Extract text blocks
                    var texts: [String] = []
                    for block in blocks {
                        if let blockType = block["type"] as? String {
                            if blockType == "text", let text = block["text"] as? String {
                                texts.append(text)
                            } else if blockType == "tool_use" {
                                let name = block["name"] as? String ?? "unknown"
                                let toolId = block["id"] as? String ?? uuid
                                var inputStrings: [String: String] = [:]
                                if let input = block["input"] as? [String: Any] {
                                    for (key, value) in input {
                                        if let str = value as? String {
                                            inputStrings[key] = str
                                        }
                                    }
                                }
                                events.append(RemoteEvent(
                                    id: toolId,
                                    type: .toolUse(name: name, input: inputStrings),
                                    timestamp: timestamp
                                ))
                            }
                        }
                    }
                    if !texts.isEmpty {
                        events.append(RemoteEvent(
                            id: uuid,
                            type: .assistant(texts.joined(separator: "\n")),
                            timestamp: timestamp
                        ))
                    }
                } else if let text = content as? String {
                    events.append(RemoteEvent(id: uuid, type: .assistant(text), timestamp: timestamp))
                }

            case "result":
                if let toolUseId = eventJson["parent_tool_use_id"] as? String {
                    var resultText = ""
                    if let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            if let text = block["text"] as? String {
                                resultText += text
                            }
                        }
                    }
                    events.append(RemoteEvent(
                        id: uuid,
                        type: .toolResult(toolUseId: toolUseId, content: resultText),
                        timestamp: timestamp
                    ))
                }

            default:
                // Skip keep_alive, control_response, etc.
                break
            }
        }

        return events
    }
}
