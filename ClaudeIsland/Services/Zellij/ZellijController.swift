//
//  ZellijController.swift
//  ClaudeIsland
//
//  Focus zellij panes and activate the terminal window for a Claude session.
//

import AppKit
import Foundation

actor ZellijController {
    static let shared = ZellijController()

    private var cachedPath: String?

    private init() {}

    // MARK: - Public API

    func focusPane(forClaudePid claudePid: Int) async -> Bool {
        guard let zellijPath = getZellijPath() else { return false }
        guard let sessionName = readZellijSessionName(forPid: claudePid) else { return false }
        let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: claudePid)
        let tabName = cwd.flatMap { findTabName(forCwd: $0, sessionName: sessionName, zellijPath: zellijPath) }
        return await switchToTab(sessionName, tabName: tabName, zellijPath: zellijPath)
    }

    func focusPane(forWorkingDirectory cwd: String) async -> Bool {
        guard let zellijPath = getZellijPath() else { return false }
        let tree = ProcessTreeBuilder.shared.buildTree()

        for zellijPid in tree.values.filter({ $0.command.lowercased().contains("zellij") }).map({ $0.pid }) {
            for pid in ProcessTreeBuilder.shared.findDescendants(of: zellijPid, tree: tree) {
                guard let sessionName = readZellijSessionName(forPid: pid),
                      let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                      processCwd == cwd else { continue }
                let tabName = findTabName(forCwd: cwd, sessionName: sessionName, zellijPath: zellijPath)
                return await switchToTab(sessionName, tabName: tabName, zellijPath: zellijPath)
            }
        }
        return false
    }

    // MARK: - Path

    func getZellijPath() -> String? {
        if let cached = cachedPath { return cached }
        let candidates = ["/opt/homebrew/bin/zellij", "/usr/local/bin/zellij", "/usr/bin/zellij"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            cachedPath = found
            return found
        }
        return nil
    }

    // MARK: - Session Name

    private nonisolated func readZellijSessionName(forPid pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/bin/ps", arguments: ["eww", "-p", String(pid)]
        ) else { return nil }

        for token in output.split(separator: " ") {
            let s = String(token)
            if s.hasPrefix("ZELLIJ_SESSION_NAME=") {
                return String(s.dropFirst("ZELLIJ_SESSION_NAME=".count))
            }
        }
        return nil
    }

    // MARK: - Tab Discovery

    /// Find the tab name in `dump-layout` whose pane cwd matches `targetCwd`.
    private nonisolated func findTabName(forCwd targetCwd: String, sessionName: String, zellijPath: String) -> String? {
        guard let layout = ProcessExecutor.shared.runSyncOrNil(
            zellijPath, arguments: ["--session", sessionName, "action", "dump-layout"]
        ) else { return nil }
        return parseTabContaining(cwd: targetCwd, fromLayout: layout)
    }

    /// Single-pass KDL layout parser.
    ///
    /// Layout structure (relevant lines):
    ///   layout {
    ///     cwd "/absolute/base"          ← least-indented cwd line is the base
    ///     tab name="foo" { ... }
    ///       pane cwd="relative/path"    ← relative to base
    ///   }
    private nonisolated func parseTabContaining(cwd targetCwd: String, fromLayout layout: String) -> String? {
        var baseCwd = ""
        var baseCwdIndent = Int.max
        var currentTab: String? = nil

        for line in layout.components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("cwd \"") && indent < baseCwdIndent {
                baseCwdIndent = indent
                baseCwd = extractKDLString(from: trimmed, after: "cwd ")
            } else if trimmed.hasPrefix("tab ") {
                currentTab = extractKDLStringAttr(key: "name", from: trimmed)
            } else if trimmed.hasPrefix("pane "), let paneCwd = extractKDLStringAttr(key: "cwd", from: trimmed) {
                let absolute = paneCwd.hasPrefix("/") ? paneCwd : "\(baseCwd)/\(paneCwd)"
                if absolute == targetCwd, let tab = currentTab { return tab }
            }
        }
        return nil
    }

    /// Extract a quoted string value: `key="value"` → `"value"`.
    private nonisolated func extractKDLStringAttr(key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"", options: .literal) else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    /// Extract a bare quoted string: `prefix "value"` → `"value"`.
    private nonisolated func extractKDLString(from line: String, after prefix: String) -> String {
        let trimmed = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        return trimmed.trimmingCharacters(in: .init(charactersIn: "\" "))
            .components(separatedBy: "\"").first ?? ""
    }

    // MARK: - Focus

    private func switchToTab(_ sessionName: String, tabName: String?, zellijPath: String) async -> Bool {
        if let tab = tabName {
            _ = try? await ProcessExecutor.shared.run(
                zellijPath,
                arguments: ["--session", sessionName, "action", "go-to-tab-name", tab]
            )
        }
        return activateTerminalWindow()
    }

    @discardableResult
    private nonisolated func activateTerminalWindow() -> Bool {
        for bundleId in TerminalAppRegistry.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate(options: .activateIgnoringOtherApps)
                return true
            }
        }
        return false
    }
}
