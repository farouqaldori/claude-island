//
//  KeychainCredentialReader.swift
//  ClaudeIsland
//
//  Reads Claude Code OAuth credentials from the macOS Keychain
//

import Foundation
import os.log
import Security

/// Reads OAuth credentials stored by Claude Code in the macOS Keychain
struct KeychainCredentialReader {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "Keychain")

    struct Credentials {
        let accessToken: String
        let organizationId: String?
    }

    /// Read Claude Code OAuth credentials from the Keychain via security CLI
    static func readCredentials() -> Credentials? {
        DebugFileLogger.log("readCredentials: reading via security CLI...")

        // Use CLI first (avoids SecItemCopyMatching blocking on keychain permission dialogs)
        if let creds = searchWithCLI() {
            return creds
        }

        // Fall back to settings.json
        return readFromSettingsFile()
    }

    private static func searchWithCLI() -> Credentials? {
        // Use -w flag to output just the password value, -a for current user account
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-a", NSUserName(),
            "-w"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let password = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DebugFileLogger.log("searchWithCLI: exit=\(process.terminationStatus), password length=\(password.count)")
            DebugFileLogger.log("searchWithCLI: first 200 chars=\(String(password.prefix(200)))")

            if !password.isEmpty {
                return parsePassword(password)
            }
        } catch {
            DebugFileLogger.log("searchWithCLI: failed: \(error.localizedDescription)")
        }

        DebugFileLogger.log("searchWithCLI: falling back to settings.json...")
        return readFromSettingsFile()
    }

    /// Parse a password string — may be JSON with nested credentials or a plain token
    private static func parsePassword(_ password: String) -> Credentials? {
        guard let jsonData = password.data(using: .utf8) else {
            DebugFileLogger.log("parsePassword: failed to convert to data")
            return Credentials(accessToken: password, organizationId: nil)
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                DebugFileLogger.log("parsePassword: JSON is not a dictionary, using as plain token")
                return Credentials(accessToken: password, organizationId: nil)
            }
            json = parsed
        } catch {
            DebugFileLogger.log("parsePassword: JSON parse error: \(error.localizedDescription)")
            DebugFileLogger.log("parsePassword: using as plain token (length=\(password.count))")
            return Credentials(accessToken: password, organizationId: nil)
        }

        DebugFileLogger.log("parsePassword: JSON keys=\(Array(json.keys))")

        // Direct accessToken at top level
        if let token = json["accessToken"] as? String {
            let orgId = json["organizationUuid"] as? String
            DebugFileLogger.log("parsePassword: FOUND direct token (length=\(token.count), orgId=\(orgId ?? "nil"))")
            return Credentials(accessToken: token, organizationId: orgId)
        }

        // Nested under claudeAiOauth
        if let oauth = json["claudeAiOauth"] as? [String: Any] {
            DebugFileLogger.log("parsePassword: claudeAiOauth keys=\(Array(oauth.keys))")
            if let token = oauth["accessToken"] as? String {
                let orgId = oauth["organizationUuid"] as? String
                DebugFileLogger.log("parsePassword: FOUND nested token (length=\(token.count), orgId=\(orgId ?? "nil"))")
                return Credentials(accessToken: token, organizationId: orgId)
            }
        }

        // Try any nested dictionary that has accessToken
        for (key, value) in json {
            if let nested = value as? [String: Any], let token = nested["accessToken"] as? String {
                let orgId = nested["organizationUuid"] as? String
                DebugFileLogger.log("parsePassword: FOUND token under '\(key)' (length=\(token.count), orgId=\(orgId ?? "nil"))")
                return Credentials(accessToken: token, organizationId: orgId)
            }
        }

        DebugFileLogger.log("parsePassword: no accessToken found in JSON")
        return nil
    }

    private static func readFromSettingsFile() -> Credentials? {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        DebugFileLogger.log("readFromSettingsFile: checking \(settingsPath)")

        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            DebugFileLogger.log("readFromSettingsFile: file not found or not readable")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugFileLogger.log("readFromSettingsFile: failed to parse JSON")
            return nil
        }

        let keys = Array(json.keys)
        DebugFileLogger.log("readFromSettingsFile: keys=\(keys)")

        if let oauthAccount = json["oauthAccount"] as? [String: Any],
           let token = oauthAccount["accessToken"] as? String {
            let orgId = oauthAccount["organizationUuid"] as? String
            DebugFileLogger.log("readFromSettingsFile: FOUND credentials (token length=\(token.count), orgId=\(orgId ?? "nil"))")
            return Credentials(accessToken: token, organizationId: orgId)
        }

        DebugFileLogger.log("readFromSettingsFile: no oauthAccount found")
        return nil
    }
}
