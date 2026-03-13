//
//  RemoteControlManager.swift
//  ClaudeIsland
//
//  Manages messaging to Claude Code sessions via the Anthropic bridge API.
//  Requires remote control to be enabled on the CLI session (/remote-control).
//  Reads the cloud session ID from bridge-pointer.json and sends events
//  through the /v1/sessions/{id}/events endpoint.
//

import Foundation
import os.log

/// Manages remote-control bridge messaging to Claude Code sessions
actor RemoteControlManager {
    static let shared = RemoteControlManager()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "RemoteControl")

    /// Cached bridge pointers: local cwd → cloud session ID
    private var bridgePointers: [String: BridgePointer] = [:]

    /// Whether credentials are available
    private var hasCredentials: Bool = false

    private init() {}

    /// Bridge pointer data from bridge-pointer.json
    private struct BridgePointer {
        let sessionId: String      // Cloud session ID (e.g., "session_01ShT4d23sWtqtQtZwmoA68v")
        let environmentId: String  // Environment ID (e.g., "env_01BoYTHUpZAryJYMidQZHbqa")
    }

    // MARK: - Initialization

    /// Check if remote-control is available (credentials exist)
    func checkAvailability() async -> Bool {
        DebugFileLogger.log("checkAvailability called")
        do {
            _ = try await AnthropicBridgeClient.shared.loadCredentials()
            hasCredentials = true
            DebugFileLogger.log("checkAvailability: credentials FOUND")
            return true
        } catch {
            hasCredentials = false
            DebugFileLogger.log("checkAvailability: NO credentials - \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Session Messaging

    /// Send a user message to a Claude session via the bridge API
    func sendMessage(_ text: String, sessionId: String, cwd: String, tty: String? = nil) async -> Bool {
        DebugFileLogger.log("sendMessage ENTER: text='\(text.prefix(50))', sessionId=\(sessionId), cwd=\(cwd)")

        // Determine cloud session ID
        let cloudSessionId: String
        if sessionId.hasPrefix("remote-") {
            // Remote API session — cloud ID is embedded in the session ID
            cloudSessionId = String(sessionId.dropFirst("remote-".count))
            DebugFileLogger.log("sendMessage: remote session, cloudSessionId=\(cloudSessionId)")
        } else {
            // Local session — look up cloud ID from bridge-pointer.json
            guard let pointer = loadBridgePointer(forCwd: cwd) else {
                DebugFileLogger.log("sendMessage: no bridge-pointer.json found — is remote control enabled? (/remote-control)")
                return false
            }
            cloudSessionId = pointer.sessionId
            DebugFileLogger.log("sendMessage: local session, cloudSessionId=\(cloudSessionId)")
        }

        // Ensure we have credentials
        if !hasCredentials {
            guard await checkAvailability() else {
                DebugFileLogger.log("sendMessage: no credentials available")
                return false
            }
        }

        // Build the event (same format as Claude desktop app)
        let uuid = UUID().uuidString.lowercased()
        let event: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "session_id": cloudSessionId,
            "parent_tool_use_id": NSNull(),
            "message": [
                "role": "user",
                "content": text
            ]
        ]

        do {
            try await AnthropicBridgeClient.shared.sendEvents(
                sessionId: cloudSessionId,
                events: [event]
            )
            DebugFileLogger.log("sendMessage: SUCCESS")
            return true
        } catch let error as BridgeAPIError {
            DebugFileLogger.log("sendMessage: bridge API error: \(error.localizedDescription ?? "unknown")")
            if case .httpError(401, _) = error {
                await AnthropicBridgeClient.shared.clearCredentials()
                hasCredentials = false
            }
            return false
        } catch {
            DebugFileLogger.log("sendMessage: error: \(error.localizedDescription)")
            return false
        }
    }

    /// Check if a session can receive messages (bridge pointer exists)
    func canSendMessages(sessionId: String, cwd: String) -> Bool {
        loadBridgePointer(forCwd: cwd) != nil
    }

    // MARK: - Bridge Pointer

    /// Read bridge-pointer.json for a working directory
    private func loadBridgePointer(forCwd cwd: String) -> BridgePointer? {
        // Check cache
        if let cached = bridgePointers[cwd] {
            return cached
        }

        // Convert cwd to Claude's project path format
        let projectPath = cwd.replacingOccurrences(of: "/", with: "-")
        let pointerPath = NSHomeDirectory() + "/.claude/projects/\(projectPath)/bridge-pointer.json"

        guard let data = FileManager.default.contents(atPath: pointerPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cloudSessionId = json["sessionId"] as? String,
              let envId = json["environmentId"] as? String else {
            DebugFileLogger.log("loadBridgePointer: not found at \(pointerPath)")
            return nil
        }

        let pointer = BridgePointer(sessionId: cloudSessionId, environmentId: envId)
        bridgePointers[cwd] = pointer
        DebugFileLogger.log("loadBridgePointer: found sessionId=\(cloudSessionId), envId=\(envId)")
        return pointer
    }

    /// Invalidate cached bridge pointer (e.g., when session reconnects)
    func invalidateBridgePointer(forCwd cwd: String) {
        bridgePointers.removeValue(forKey: cwd)
    }

    /// Mark a session as messageable
    func markSessionMessageable(_ sessionId: String) {
        // No-op — bridge pointer is the source of truth
    }

    /// Remove a session
    func removeSession(_ sessionId: String) {
        // No-op — bridge pointer cleanup happens via invalidateBridgePointer
    }

    /// Clean up
    func cleanupAll() async {
        bridgePointers.removeAll()
    }
}
