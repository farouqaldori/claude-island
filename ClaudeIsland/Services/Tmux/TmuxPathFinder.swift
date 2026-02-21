//
//  TmuxPathFinder.swift
//  ClaudeIsland
//
//  Finds tmux executable path
//

import Foundation

/// Finds and caches the tmux executable path
actor TmuxPathFinder {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxPathFinder()

    /// Get the path to tmux executable
    func getTmuxPath() -> String? {
        if let cached = cachedPath {
            return cached
        }

        let possiblePaths = [
            "/opt/homebrew/bin/tmux", // Apple Silicon Homebrew
            "/usr/local/bin/tmux", // Intel Homebrew
            "/usr/bin/tmux", // System
            "/bin/tmux",
        ]

        if let foundPath = possiblePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            self.cachedPath = foundPath
            return foundPath
        }

        return nil
    }

    /// Check if tmux is available
    func isTmuxAvailable() -> Bool {
        self.getTmuxPath() != nil
    }

    // MARK: Private

    private var cachedPath: String?
}
