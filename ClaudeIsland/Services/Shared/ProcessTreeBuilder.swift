//
//  ProcessTreeBuilder.swift
//  ClaudeIsland
//
//  Builds and queries process trees using ps command
//

import Foundation

// MARK: - ProcessInfo

/// Information about a process in the tree
nonisolated struct ProcessInfo: Sendable {
    let pid: Int
    let ppid: Int
    let command: String
    let tty: String?
}

// MARK: - ProcessTree

/// Indexed process tree with O(1) parent→children lookup
nonisolated struct ProcessTree: Sendable {
    // MARK: Lifecycle

    /// Create an indexed process tree from process info dictionary
    nonisolated init(info: [Int: ProcessInfo]) {
        self.infoByPID = info

        // Build parent→children index during construction
        var children: [Int: [Int]] = [:]
        children.reserveCapacity(info.count / 4) // Estimate ~4 children per parent on average
        for (pid, processInfo) in info {
            children[processInfo.ppid, default: []].append(pid)
        }
        self.childrenByPID = children
    }

    // MARK: Internal

    /// PID → ProcessInfo mapping
    let infoByPID: [Int: ProcessInfo]

    /// Parent PID → Child PIDs index for O(1) descendant lookup
    let childrenByPID: [Int: [Int]]
}

// MARK: - ProcessTreeBuilder

/// Builds and queries the system process tree
nonisolated struct ProcessTreeBuilder: Sendable {
    // MARK: Lifecycle

    private nonisolated init() {}

    // MARK: Internal

    nonisolated static let shared = Self()

    /// Build a process tree mapping PID -> ProcessInfo
    nonisolated func buildTree() -> [Int: ProcessInfo] {
        self.buildInfoDict()
    }

    /// Build an indexed process tree with O(1) children lookup
    nonisolated func buildIndexedTree() -> ProcessTree {
        ProcessTree(info: self.buildInfoDict())
    }

    /// Check if a process has tmux in its parent chain
    nonisolated func isInTmux(pid: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }
            if info.command.lowercased().contains("tmux") {
                return true
            }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Walk up the process tree to find the terminal app PID
    nonisolated func findTerminalPID(forProcess pid: Int, tree: [Int: ProcessInfo]) -> Int? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }

            if TerminalAppRegistry.isTerminal(info.command) {
                return current
            }

            current = info.ppid
            depth += 1
        }

        return nil
    }

    /// Check if targetPID is a descendant of ancestorPID
    nonisolated func isDescendant(targetPID: Int, ofAncestor ancestorPID: Int, tree: [Int: ProcessInfo]) -> Bool {
        var current = targetPID
        var depth = 0

        while current > 1 && depth < 50 {
            if current == ancestorPID {
                return true
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return false
    }

    /// Find all descendant PIDs of a given process (O(n) - scans entire tree)
    /// Prefer `findDescendants(of:indexedTree:)` for O(d) performance where d = descendant count
    nonisolated func findDescendants(of pid: Int, tree: [Int: ProcessInfo]) -> Set<Int> {
        var descendants: Set<Int> = []
        var queue = [pid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (childPID, info) in tree where info.ppid == current {
                if !descendants.contains(childPID) {
                    descendants.insert(childPID)
                    queue.append(childPID)
                }
            }
        }

        return descendants
    }

    /// Find all descendant PIDs using indexed tree (O(d) where d = descendant count)
    nonisolated func findDescendants(of pid: Int, indexedTree: ProcessTree) -> Set<Int> {
        var descendants: Set<Int> = []
        var queue = [pid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            // O(1) children lookup via index
            if let children = indexedTree.childrenByPID[current] {
                for childPID in children where !descendants.contains(childPID) {
                    descendants.insert(childPID)
                    queue.append(childPID)
                }
            }
        }

        return descendants
    }

    /// Get working directory for a process using lsof
    nonisolated func getWorkingDirectory(forPID pid: Int) -> String? {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"]) else {
            return nil
        }

        var foundCwd = false
        for line in output.components(separatedBy: "\n") {
            if line == "fcwd" {
                foundCwd = true
            } else if foundCwd && line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }

    // MARK: Private

    /// Internal: Build the raw info dictionary
    private nonisolated func buildInfoDict() -> [Int: ProcessInfo] {
        guard let output = ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,comm"]) else {
            return [:]
        }

        var tree: [Int: ProcessInfo] = [:]

        // Use split() which returns Substrings - more efficient than components()
        for line in output.split(separator: "\n") {
            // Split on whitespace, filtering empty strings
            let parts = line.split(whereSeparator: \.isWhitespace)

            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1])
            else { continue }

            let tty = parts[2] == "??" ? nil : String(parts[2])
            let command = parts[3...].joined(separator: " ")

            tree[pid] = ProcessInfo(pid: pid, ppid: ppid, command: command, tty: tty)
        }

        return tree
    }
}
