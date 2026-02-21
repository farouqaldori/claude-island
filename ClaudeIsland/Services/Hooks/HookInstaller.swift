//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation
import os.log

// MARK: - HookInstaller

/// Hook installer — MainActor (default) protects static mutable state
/// This ensures thread-safe access to detectedRuntime across all call sites
enum HookInstaller {
    // MARK: Internal

    /// Cached detected runtime for command generation
    /// Protected by @MainActor isolation to prevent data races
    private(set) static var detectedRuntime: PythonRuntimeDetector.PythonRuntime?

    /// Install hook script and update settings.json on app launch
    /// Supports cooperative cancellation - checks Task.isCancelled at key points
    static func installIfNeeded() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        // Check for cancellation before file operations
        guard !Task.isCancelled else { return }

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true,
        )

        if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path,
            )
        }

        // Check for cancellation before async runtime detection
        guard !Task.isCancelled else { return }

        await self.detectPythonRuntime()

        // Check for cancellation after async operation (state may have changed)
        guard !Task.isCancelled else { return }

        // Skip settings update if no runtime available (alert was already shown during detection)
        // Use ? suffix for optional pattern matching (required to match .some(.unavailable(...)))
        if case .unavailable? = self.detectedRuntime {
            return
        }
        self.updateSettings(at: settings)
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                // Check both modern wrapped format and legacy direct format
                for entry in entries where self.containsClaudeIslandCommand(entry) {
                    return true
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent("claude-island-state.py")
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any]
        else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                // Remove both modern wrapped format and legacy direct format entries
                entries.removeAll { entry in
                    self.containsClaudeIslandCommand(entry)
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys],
        ) {
            try? data.write(to: settings)
        }
    }

    // MARK: Private

    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "HookInstaller")

    /// Detect the best available Python runtime
    private static func detectPythonRuntime() async {
        self.detectedRuntime = await PythonRuntimeDetector.shared.detectRuntime()

        // Already on MainActor, can call directly without wrapper
        // Use ? suffix for optional pattern matching (required to match .some(.unavailable(...)))
        if case let .unavailable(reason)? = detectedRuntime {
            PythonRuntimeAlert.showUnavailableAlert(reason: reason)
        }
    }

    private static func updateSettings(at settingsURL: URL) {
        guard let runtime = detectedRuntime,
              let command = PythonRuntimeDetector.shared.getCommand(
                  for: "~/.claude/hooks/claude-island-state.py",
                  runtime: runtime,
              )
        else {
            self.logger.warning("Skipping hook settings update - no suitable Python runtime")
            return
        }

        Self.logger.info("Using hook command: \(command)")

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let hookEvents = self.buildHookConfigurations(command: command)

        for (event, config) in hookEvents {
            hooks[event] = self.updateOrAddHookEntries(
                existing: hooks[event] as? [[String: Any]],
                config: config,
                command: command,
                eventName: event,
            )
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL)
        }
    }

    /// Build hook configurations for all events
    private static func buildHookConfigurations(command: String) -> [(String, [[String: Any]])] {
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        return [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]
    }

    /// Update existing hook entries or add new ones, deduplicating claude-island entries by matcher
    private static func updateOrAddHookEntries(
        existing: [[String: Any]]?,
        config: [[String: Any]],
        command: String,
        eventName: String,
    ) -> [[String: Any]] {
        guard var existingEvent = existing else {
            return config
        }

        // First, remove any legacy direct format entries (not wrapped in "hooks")
        existingEvent.removeAll { self.isLegacyDirectEntry($0) }

        // Deduplicate and update claude-island entries, preserving user hooks
        let (updatedEntries, seenMatchers) = self.deduplicateClaudeIslandEntries(
            in: existingEvent, command: command, eventName: eventName,
        )
        existingEvent = updatedEntries

        // Add any missing configurations (matchers not already present)
        for configEntry in config {
            let configMatcher = (configEntry["matcher"] as? String) ?? ""
            if !seenMatchers.contains(configMatcher) {
                existingEvent.append(configEntry)
            }
        }

        return existingEvent
    }

    /// Deduplicate claude-island entries by matcher, merging user hooks from duplicates
    /// Returns updated entries and set of seen matchers
    private static func deduplicateClaudeIslandEntries(
        in entries: [[String: Any]],
        command: String,
        eventName: String,
    ) -> ([[String: Any]], Set<String>) {
        var result = entries
        var matcherToFirstIndex: [String: Int] = [:]
        var indicesToRemove = [Int]()

        for i in result.indices {
            guard var entryHooks = result[i]["hooks"] as? [[String: Any]],
                  self.isClaudeIslandHookEntry(entryHooks)
            else { continue }

            let matcherKey = (result[i]["matcher"] as? String) ?? ""

            if let firstIndex = matcherToFirstIndex[matcherKey] {
                // Duplicate - merge user hooks into first entry, then mark for removal
                self.mergeUserHooks(from: entryHooks, into: &result, at: firstIndex, eventName: eventName)
                indicesToRemove.append(i)
            } else {
                // First occurrence - update command and track matcher
                matcherToFirstIndex[matcherKey] = i
                self.updateClaudeIslandCommand(in: &entryHooks, to: command)
                result[i]["hooks"] = entryHooks
            }
        }

        // Remove duplicates in reverse order to preserve indices
        if !indicesToRemove.isEmpty {
            Self.logger.info("Removed \(indicesToRemove.count) duplicate claude-island hook entry(ies) from \(eventName)")
            for index in indicesToRemove.reversed() {
                result.remove(at: index)
            }
        }

        return (result, Set(matcherToFirstIndex.keys))
    }

    /// Check if hooks array contains a claude-island hook
    private static func isClaudeIslandHookEntry(_ hooks: [[String: Any]]) -> Bool {
        hooks.contains { hook in
            (hook["command"] as? String)?.contains("claude-island-state.py") == true
        }
    }

    /// Merge non-claude-island hooks from source into the target entry
    private static func mergeUserHooks(
        from sourceHooks: [[String: Any]],
        into entries: inout [[String: Any]],
        at targetIndex: Int,
        eventName: String,
    ) {
        let userHooks = sourceHooks.filter { hook in
            guard let cmd = hook["command"] as? String else { return true }
            return !cmd.contains("claude-island-state.py")
        }

        guard !userHooks.isEmpty,
              var targetHooks = entries[targetIndex]["hooks"] as? [[String: Any]]
        else { return }

        targetHooks.append(contentsOf: userHooks)
        entries[targetIndex]["hooks"] = targetHooks
        Self.logger.info("Merged \(userHooks.count) user hook(s) from duplicate entry in \(eventName)")
    }

    /// Update claude-island command in hooks array
    private static func updateClaudeIslandCommand(in hooks: inout [[String: Any]], to command: String) {
        for j in hooks.indices {
            if let cmd = hooks[j]["command"] as? String, cmd.contains("claude-island-state.py") {
                hooks[j]["command"] = command
            }
        }
    }

    /// Check if entry is a legacy direct format (type: command at top level, not wrapped in hooks)
    private static func isLegacyDirectEntry(_ entry: [String: Any]) -> Bool {
        // Legacy format: {"type": "command", "command": "...claude-island-state.py..."}
        // Modern format: {"hooks": [{"type": "command", "command": "..."}]}
        if entry["hooks"] != nil {
            return false // This is the modern wrapped format
        }
        if let type = entry["type"] as? String, type == "command",
           let cmd = entry["command"] as? String,
           cmd.contains("claude-island-state.py") {
            return true
        }
        return false
    }

    /// Check if entry contains a Claude Island command (either wrapped or direct format)
    private static func containsClaudeIslandCommand(_ entry: [String: Any]) -> Bool {
        // Check modern wrapped format: {"hooks": [{"type": "command", "command": "..."}]}
        if let entryHooks = entry["hooks"] as? [[String: Any]] {
            for hook in entryHooks {
                if let cmd = hook["command"] as? String,
                   cmd.contains("claude-island-state.py") {
                    return true
                }
            }
        }
        // Check legacy direct format: {"type": "command", "command": "..."}
        if self.isLegacyDirectEntry(entry) {
            return true
        }
        return false
    }
}
