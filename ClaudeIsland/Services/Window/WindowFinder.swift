//
//  WindowFinder.swift
//  ClaudeIsland
//
//  Finds windows using yabai window manager
//

import Foundation

// MARK: - YabaiWindow

/// Information about a yabai window
struct YabaiWindow: Sendable {
    // MARK: Lifecycle

    nonisolated init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? Int,
              let pid = dict["pid"] as? Int
        else { return nil }

        self.id = id
        self.pid = pid
        self.title = dict["title"] as? String ?? ""
        self.space = dict["space"] as? Int ?? 0
        self.isVisible = dict["is-visible"] as? Bool ?? false
        self.hasFocus = dict["has-focus"] as? Bool ?? false
    }

    // MARK: Internal

    let id: Int
    let pid: Int
    let title: String
    let space: Int
    let isVisible: Bool
    let hasFocus: Bool
}

// MARK: - WindowFinder

/// Finds windows using yabai
actor WindowFinder {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = WindowFinder()

    /// Check if yabai is available (caches result)
    func isYabaiAvailable() -> Bool {
        if let cached = isAvailableCache { return cached }

        let paths = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        if let foundPath = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            self.yabaiPath = foundPath
            self.isAvailableCache = true
            return true
        }
        self.isAvailableCache = false
        return false
    }

    /// Get the yabai path if available
    func getYabaiPath() -> String? {
        _ = self.isYabaiAvailable()
        return self.yabaiPath
    }

    /// Get all windows from yabai
    func getAllWindows() async -> [YabaiWindow] {
        guard self.isYabaiAvailable(), let path = yabaiPath else { return [] }

        do {
            let output = try await ProcessExecutor.shared.run(path, arguments: ["-m", "query", "--windows"])
            guard let data = output.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                return []
            }
            return jsonArray.compactMap { YabaiWindow(from: $0) }
        } catch {
            return []
        }
    }

    /// Get the current space number
    nonisolated func getCurrentSpace(windows: [YabaiWindow]) -> Int? {
        windows.first { $0.hasFocus }?.space
    }

    /// Find windows for a terminal PID
    nonisolated func findWindows(forTerminalPID pid: Int, windows: [YabaiWindow]) -> [YabaiWindow] {
        windows.filter { $0.pid == pid }
    }

    /// Find tmux window (title contains "tmux")
    nonisolated func findTmuxWindow(forTerminalPID pid: Int, windows: [YabaiWindow]) -> YabaiWindow? {
        windows.first { $0.pid == pid && $0.title.lowercased().contains("tmux") }
    }

    /// Find any non-Claude window for a terminal
    nonisolated func findNonClaudeWindow(forTerminalPID pid: Int, windows: [YabaiWindow]) -> YabaiWindow? {
        windows.first { $0.pid == pid && !$0.title.contains("✳") }
    }

    // MARK: Private

    private var yabaiPath: String?
    private var isAvailableCache: Bool?
}
