//
//  OAuthLoginManager.swift
//  ClaudeIsland
//
//  Manages OAuth login for the Anthropic bridge API.
//  Runs `claude login` to perform the OAuth flow, then reads credentials.
//

import Foundation
import Combine

/// Manages OAuth login state and triggers `claude login`
@MainActor
class OAuthLoginManager: ObservableObject {
    static let shared = OAuthLoginManager()

    enum LoginState: Equatable {
        case unknown       // Haven't checked yet
        case loggedOut     // No credentials found
        case loggingIn     // `claude login` running
        case loggedIn      // Credentials available
        case error(String) // Login failed
    }

    @Published var state: LoginState = .unknown

    private var loginProcess: Process?

    private init() {}

    /// Check if OAuth credentials are available (runs keychain check on background thread)
    func checkCredentials() {
        DebugFileLogger.log("OAuthLoginManager: checking credentials")
        Task.detached {
            let creds = KeychainCredentialReader.readCredentials()
            await MainActor.run {
                if creds != nil {
                    DebugFileLogger.log("OAuthLoginManager: credentials FOUND")
                    self.state = .loggedIn
                } else {
                    DebugFileLogger.log("OAuthLoginManager: no credentials")
                    self.state = .loggedOut
                }
            }
        }
    }

    /// Start the OAuth login flow by running `claude login`
    func startLogin() {
        guard state != .loggingIn else { return }
        state = .loggingIn
        DebugFileLogger.log("OAuthLoginManager: starting login")

        Task {
            await performLogin()
        }
    }

    /// Cancel an in-progress login
    func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        state = .loggedOut
    }

    private func performLogin() async {
        // Find the claude binary
        let claudePath = await findClaudeBinary()
        guard let claudePath else {
            DebugFileLogger.log("OAuthLoginManager: claude binary not found")
            state = .error("Claude Code not found")
            return
        }

        DebugFileLogger.log("OAuthLoginManager: using claude at \(claudePath)")

        // Run `claude login` which opens the browser for OAuth
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "login"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Strip Claude Code env vars so it doesn't think it's nested
        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRY_TOOL_USE_ID")
        env.removeValue(forKey: "CLAUDE_CODE_TASK_ID")
        process.environment = env

        loginProcess = process

        do {
            try process.run()
            DebugFileLogger.log("OAuthLoginManager: claude login started (pid=\(process.processIdentifier))")

            // Wait in background
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            let exitCode = process.terminationStatus
            let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            DebugFileLogger.log("OAuthLoginManager: claude login exited with \(exitCode)")
            DebugFileLogger.log("OAuthLoginManager: stdout=\(stdout.prefix(200))")
            DebugFileLogger.log("OAuthLoginManager: stderr=\(stderr.prefix(200))")

            loginProcess = nil

            // Check if credentials are now available
            // Clear any cached credentials first
            await AnthropicBridgeClient.shared.clearCredentials()

            if KeychainCredentialReader.readCredentials() != nil {
                DebugFileLogger.log("OAuthLoginManager: login SUCCESS - credentials now available")
                state = .loggedIn
                // Also notify RemoteControlManager
                _ = await RemoteControlManager.shared.checkAvailability()
            } else if exitCode == 0 {
                // Process exited OK but no credentials - might need a moment
                try? await Task.sleep(for: .seconds(1))
                if KeychainCredentialReader.readCredentials() != nil {
                    DebugFileLogger.log("OAuthLoginManager: login SUCCESS (delayed)")
                    state = .loggedIn
                    _ = await RemoteControlManager.shared.checkAvailability()
                } else {
                    DebugFileLogger.log("OAuthLoginManager: login completed but no credentials found")
                    state = .error("Login completed but no credentials")
                }
            } else {
                DebugFileLogger.log("OAuthLoginManager: login FAILED")
                state = .error("Login failed (exit \(exitCode))")
            }
        } catch {
            DebugFileLogger.log("OAuthLoginManager: failed to launch: \(error.localizedDescription)")
            loginProcess = nil
            state = .error(error.localizedDescription)
        }
    }

    private func findClaudeBinary() async -> String? {
        // Check common locations
        let candidates = [
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which claude`
        do {
            let output = try await ProcessExecutor.shared.run(
                "/usr/bin/which",
                arguments: ["claude"]
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}

        return nil
    }
}
