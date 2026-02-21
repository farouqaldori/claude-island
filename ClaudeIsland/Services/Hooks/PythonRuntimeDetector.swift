//
//  PythonRuntimeDetector.swift
//  ClaudeIsland
//
//  Detects the best available Python runtime for executing hooks
//  Follows TmuxPathFinder.swift pattern for executable discovery with caching
//

import Foundation
import os.log

// MARK: - PythonRuntimeDetector

/// Actor that handles Python runtime detection with caching
/// Follows TmuxPathFinder.swift pattern for executable discovery
actor PythonRuntimeDetector {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    /// Detected Python runtime - Sendable for cross-actor safety
    enum PythonRuntime: Equatable, Sendable {
        case uvRun(path: String)
        case directPython(path: String, version: String)
        case unavailable(reason: UnavailableReason)
    }

    /// Reason why no suitable runtime was found
    enum UnavailableReason: Equatable, Sendable {
        case noPythonFound
        case pythonTooOld(foundVersion: String)
    }

    static let shared = PythonRuntimeDetector()

    /// Minimum required Python version
    static let minimumPythonVersion = (major: 3, minor: 14)

    /// Detect best available Python runtime (cached after first call)
    func detectRuntime() async -> PythonRuntime {
        // Return cached result if available
        if let cached = cachedRuntime {
            return cached
        }

        // If detection already in progress, await existing task (reentrancy-safe)
        if let existingTask = detectionTask {
            return await existingTask.value
        }

        // Start new detection task, store BEFORE await (per Swift guidelines)
        let task = Task(name: "detect-python") { await self.performDetection() }
        self.detectionTask = task

        let runtime = await task.value
        self.cachedRuntime = runtime
        self.detectionTask = nil
        return runtime
    }

    /// Get command string for running script with detected runtime
    /// Returns nil if runtime unavailable
    nonisolated func getCommand(for scriptPath: String, runtime: PythonRuntime) -> String? {
        switch runtime {
        case let .uvRun(path):
            "\(path) run \(scriptPath)"
        case let .directPython(path, _):
            "\(path) \(scriptPath)"
        case .unavailable:
            nil
        }
    }

    /// Clear cached runtime (for testing or forced refresh)
    /// Cancels any in-flight detection task to prevent stale results from overwriting the cache
    func clearCache() {
        self.detectionTask?.cancel()
        self.cachedRuntime = nil
        self.detectionTask = nil
    }

    // MARK: Private

    /// Logger for Python runtime detection
    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "PythonRuntimeDetector")

    /// Cached detection result
    private var cachedRuntime: PythonRuntime?

    /// In-flight detection task (reentrancy-safe pattern per Swift guidelines)
    private var detectionTask: Task<PythonRuntime, Never>?

    /// Perform the actual runtime detection
    private func performDetection() async -> PythonRuntime {
        Self.logger.info("Starting Python runtime detection")

        // Tier 1: Check for uv
        if let uvPath = await findUv() {
            Self.logger.info("Found uv at \(uvPath)")
            return .uvRun(path: uvPath)
        }

        // Tier 2: Check for Python 3.14+
        if let (pythonPath, version) = await findPython314() {
            Self.logger.info("Found Python \(version) at \(pythonPath)")
            return .directPython(path: pythonPath, version: version)
        }

        // Tier 3: Check for any Python and report version mismatch
        if let (_, version) = await findAnyPython() {
            Self.logger.warning("Found Python \(version) but need 3.14+")
            return .unavailable(reason: .pythonTooOld(foundVersion: version))
        }

        Self.logger.warning("No Python runtime found")
        return .unavailable(reason: .noPythonFound)
    }

    /// Find uv executable
    private func findUv() async -> String? {
        let localBinUv = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/uv").path

        let possiblePaths = [
            "/opt/homebrew/bin/uv", // Apple Silicon Homebrew
            "/usr/local/bin/uv", // Intel Homebrew
            localBinUv, // Official uv installer (https://astral.sh/uv)
        ]

        // Check known paths first (like TmuxPathFinder)
        for path in possiblePaths where FileManager.default.isExecutableFile(atPath: path) {
            // Verify it actually works
            if await verifyExecutable(path, arguments: ["--version"]) {
                return path
            }
        }

        // Fallback to which
        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/which", arguments: ["uv"])
        if case let .success(processResult) = result, processResult.isSuccess {
            let path = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                // Verify it actually works (consistent with known paths check above)
                if await self.verifyExecutable(path, arguments: ["--version"]) {
                    return path
                }
            }
        }

        return nil
    }

    /// Find Python 3.14+ executable
    private func findPython314() async -> (path: String, version: String)? {
        // Check versioned paths first (most reliable)
        let versionedPaths = [
            "/opt/homebrew/bin/python3.14", // Apple Silicon Homebrew
            "/usr/local/bin/python3.14", // Intel Homebrew
        ]

        for path in versionedPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = await getPythonVersion(path), meetsMinimumVersion(version) {
                return (path, version)
            }
        }

        // Check pyenv versions
        let pyenvBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pyenv/versions")

        if let pyenvPath = findPyenvPython314(at: pyenvBase) {
            if let version = await getPythonVersion(pyenvPath), meetsMinimumVersion(version) {
                return (pyenvPath, version)
            }
        }

        // Check generic python3 on PATH
        let genericPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in genericPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = await getPythonVersion(path), meetsMinimumVersion(version) {
                return (path, version)
            }
        }

        return nil
    }

    /// Find any Python executable (for error reporting)
    private func findAnyPython() async -> (path: String, version: String)? {
        let genericPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in genericPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = await getPythonVersion(path) {
                return (path, version)
            }
        }

        return nil
    }

    /// Find Python 3.14 in pyenv versions directory
    private func findPyenvPython314(at baseURL: URL) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
        )
        else {
            return nil
        }

        // Look for directories starting with "3.14"
        let python314Dirs = contents
            .filter { $0.lastPathComponent.hasPrefix("3.14") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // Prefer newer patch versions

        for dir in python314Dirs {
            let pythonPath = dir.appendingPathComponent("bin/python3").path
            if FileManager.default.isExecutableFile(atPath: pythonPath) {
                return pythonPath
            }
        }

        return nil
    }

    /// Get Python version string from executable
    private func getPythonVersion(_ path: String) async -> String? {
        let result = await ProcessExecutor.shared.runWithResult(path, arguments: ["--version"])
        guard case let .success(processResult) = result, processResult.isSuccess else {
            return nil
        }

        // Output is like "Python 3.14.0"
        // Note: Older Python versions (< 3.4) write to stderr instead of stdout
        let output = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedOutput = output.isEmpty
            ? (processResult.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : output
        return self.parseVersionFromOutput(combinedOutput)
    }

    /// Parse version string from "Python X.Y.Z" output
    private func parseVersionFromOutput(_ output: String) -> String? {
        // Match "Python X.Y" or "Python X.Y.Z" (handles alpha/beta suffixes)
        let pattern = #"Python (\d+\.\d+(?:\.\d+)?(?:[a-zA-Z0-9.]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output),
              ),
              let versionRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        return String(output[versionRange])
    }

    /// Check if version string meets minimum requirements
    private func meetsMinimumVersion(_ version: String) -> Bool {
        // Parse major.minor from version string
        let components = version.split(separator: ".")
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1].prefix(while: { $0.isNumber }))
        else {
            return false
        }

        if major > Self.minimumPythonVersion.major {
            return true
        }
        if major == Self.minimumPythonVersion.major && minor >= Self.minimumPythonVersion.minor {
            return true
        }
        return false
    }

    /// Verify an executable works by running it
    private func verifyExecutable(_ path: String, arguments: [String]) async -> Bool {
        let result = await ProcessExecutor.shared.runWithResult(path, arguments: arguments)
        if case let .success(processResult) = result {
            return processResult.isSuccess
        }
        return false
    }
}
