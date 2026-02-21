//
//  TmuxSessionMatcher.swift
//  ClaudeIsland
//
//  Matches tmux panes to session files by sampling visible text
//

import Foundation

/// Matches tmux panes to Claude session files by sampling pane content
actor TmuxSessionMatcher {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = TmuxSessionMatcher()

    /// Find the session ID for a tmux pane by matching visible text to session files
    /// - Parameters:
    ///   - target: The tmux target (session:window.pane)
    ///   - projectDir: The project directory containing session files
    /// - Returns: The session ID if found with high confidence
    func findSessionID(forTarget target: TmuxTarget, projectDir: URL) async -> String? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let paneContent = await capturePaneContent(tmuxPath: tmuxPath, target: target) else {
            return nil
        }

        let snippets = self.extractSnippets(from: paneContent)
        guard snippets.count >= 2 else {
            return nil
        }

        guard let sessionFiles = try? FileManager.default
            .contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
            .filter({ $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") })
        else {
            return nil
        }

        var bestMatch: (sessionID: String, score: Int)?

        for sessionURL in sessionFiles {
            let sessionID = sessionURL.deletingPathExtension().lastPathComponent
            let score = self.countMatchingSnippets(snippets: snippets, inFile: sessionURL)

            if score > 0 {
                if let existing = bestMatch {
                    if score > existing.score {
                        bestMatch = (sessionID, score)
                    }
                } else {
                    bestMatch = (sessionID, score)
                }
            }
        }

        if let match = bestMatch, match.score >= 2 {
            return match.sessionID
        }

        return nil
    }

    // MARK: Private

    // MARK: - Private Methods

    private func capturePaneContent(tmuxPath: String, target: TmuxTarget) async -> String? {
        do {
            let output = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "capture-pane", "-t", target.targetString, "-p", "-S", "-500",
            ])
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    private func extractSnippets(from content: String) -> [String] {
        var snippets: [String] = []

        let lines = content.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard trimmed.count >= 25 else { continue }

            let firstChar = trimmed.first ?? " "
            if "+-|>⏺─━═[]{}()".contains(firstChar) { continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { continue }

            let letterCount = trimmed.filter(\.isLetter).count
            guard letterCount > trimmed.count / 3 else { continue }

            let snippet = String(trimmed.prefix(80))
            snippets.append(snippet)
        }

        guard !snippets.isEmpty else { return [] }

        if snippets.count <= 5 {
            return snippets
        }

        var sampled: [String] = []
        let step = snippets.count / 5
        for i in stride(from: 0, to: snippets.count, by: max(1, step)) {
            sampled.append(snippets[i])
            if sampled.count >= 5 { break }
        }

        return sampled
    }

    private func countMatchingSnippets(snippets: [String], inFile fileURL: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return 0
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize: UInt64 = min(100_000, fileSize)
        if fileSize > readSize {
            try? handle.seek(toOffset: fileSize - readSize)
        } else {
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8)
        else {
            return 0
        }

        return snippets.count { content.contains($0) }
    }
}
