//
//  ProcessExecutor.swift
//  ClaudeIsland
//
//  Shared utility for executing shell commands with proper error handling
//  Uses swift-subprocess for async operations (Swift 6.2+)
//

import Foundation
import os.log
import Subprocess
import System

// MARK: - ProcessExecutorError

/// Errors that can occur during process execution
nonisolated enum ProcessExecutorError: Error, LocalizedError, Sendable {
    case executionFailed(command: String, exitCode: Int32, stderr: String?)
    case invalidOutput(command: String)
    case commandNotFound(String)
    case launchFailed(command: String, underlying: String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .executionFailed(command, exitCode, stderr):
            let stderrInfo = stderr.map { ", stderr: \($0)" } ?? ""
            return "Command '\(command)' failed with exit code \(exitCode)\(stderrInfo)"
        case let .invalidOutput(command):
            return "Command '\(command)' produced invalid output"
        case let .commandNotFound(command):
            return "Command not found: \(command)"
        case let .launchFailed(command, underlying):
            return "Failed to launch '\(command)': \(underlying)"
        }
    }
}

// MARK: - ProcessResult

/// Result type for process execution
nonisolated struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32
    let stderr: String?

    nonisolated var isSuccess: Bool {
        self.exitCode == 0
    }
}

// MARK: - ProcessExecuting

/// Protocol for executing shell commands (enables testing)
nonisolated protocol ProcessExecuting: Sendable {
    func run(_ executable: String, arguments: [String]) async throws(ProcessExecutorError) -> String
    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError>
    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError>
}

// MARK: - ProcessExecutor

/// Default implementation using Foundation.Process
/// Stateless service - uses struct per Swift 6 best practices (no mutable state to protect)
nonisolated struct ProcessExecutor: ProcessExecuting, Sendable {
    // MARK: Lifecycle

    private nonisolated init() {}

    // MARK: Internal

    /// Shared instance - struct has no mutable state so is inherently thread-safe
    nonisolated static let shared = Self()

    /// Logger for process execution (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "ProcessExecutor")

    /// Run a command asynchronously and return output (throws on failure)
    ///
    /// Marked @concurrent to explicitly run on the cooperative thread pool,
    /// enabling parallel subprocess execution without blocking the caller's executor.
    @concurrent
    nonisolated func run(_ executable: String, arguments: [String]) async throws(ProcessExecutorError) -> String {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case let .success(processResult):
            return processResult.output
        case let .failure(error):
            throw error
        }
    }

    /// Run a command asynchronously and return a full Result with exit code and stderr
    ///
    /// Uses swift-subprocess for efficient async execution without blocking the cooperative thread pool.
    /// Marked @concurrent to explicitly run on the cooperative thread pool.
    @concurrent
    nonisolated func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                output: .string(limit: 10_000_000),
                error: .string(limit: 1_000_000),
            )

            let stdout = result.standardOutput ?? ""
            let stderr = result.standardError

            // Extract exit code from TerminationStatus enum
            let exitCode: Int32 = switch result.terminationStatus {
            case let .exited(code): code
            case let .unhandledException(code): code
            }

            let processResult = ProcessResult(
                output: stdout,
                exitCode: exitCode,
                stderr: stderr,
            )

            if result.terminationStatus.isSuccess {
                return .success(processResult)
            } else {
                Self.logger
                    .warning(
                        "Command failed: \(executable) \(arguments.joined(separator: " "), privacy: .public) - exit code \(exitCode)",
                    )
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: exitCode,
                    stderr: stderr,
                ))
            }
        } catch {
            // Check if it's a "command not found" type error
            let errorDescription = String(describing: error)
            if errorDescription.contains("not found") || errorDescription.contains("No such file") {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            }
            Self.logger.error("Failed to launch command: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return .failure(.launchFailed(command: executable, underlying: error.localizedDescription))
        }
    }

    /// Run a command synchronously (for use in nonisolated contexts)
    /// Returns Result instead of optional for better error handling
    ///
    /// - Important: This method performs blocking I/O and must not be called from the main thread.
    ///   Use `run()` or `runWithResult()` async methods instead for main thread contexts.
    nonisolated func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        precondition(!Thread.isMainThread, "runSync must not be called on main thread - use async run() instead")
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)

            if process.terminationStatus == 0 {
                return .success(stdout)
            } else {
                Self.logger.warning("Sync command failed: \(executable, privacy: .public) - exit code \(process.terminationStatus)")
                return .failure(.executionFailed(
                    command: executable,
                    exitCode: process.terminationStatus,
                    stderr: stderr,
                ))
            }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                Self.logger.error("Command not found: \(executable, privacy: .public)")
                return .failure(.commandNotFound(executable))
            } else {
                Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                return .failure(.launchFailed(command: executable, underlying: error.localizedDescription))
            }
        } catch {
            Self.logger.error("Sync command launch failed: \(executable, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return .failure(.launchFailed(command: executable, underlying: error.localizedDescription))
        }
    }
}

// MARK: - Convenience Extensions

nonisolated extension ProcessExecutor {
    /// Run a command and return output, returning nil only if the command itself fails to execute
    /// (as opposed to non-zero exit codes which may still have useful output)
    ///
    /// Marked @concurrent to explicitly run on the cooperative thread pool.
    @concurrent
    nonisolated func runOrNil(_ executable: String, arguments: [String]) async -> String? {
        let result = await runWithResult(executable, arguments: arguments)
        switch result {
        case let .success(processResult):
            return processResult.output
        case .failure:
            return nil
        }
    }

    /// Run a command synchronously, returning nil on failure (backwards compatible)
    nonisolated func runSyncOrNil(_ executable: String, arguments: [String]) -> String? {
        switch self.runSync(executable, arguments: arguments) {
        case let .success(output):
            output
        case .failure:
            nil
        }
    }
}
