//
//  LString.swift
//  ClaudeIsland
//
//  Localization string keys for all UI text
//

import Foundation

/// All localized string keys used in the app
struct LString {
    // MARK: - Navigation

    static let back = "back"

    // MARK: - Settings Menu

    static let displayMode = "displayMode"
    static let launchAtLogin = "launchAtLogin"
    static let hooks = "hooks"
    static let starOnGitHub = "starOnGitHub"
    static let quit = "quit"

    // MARK: - Language

    static let language = "language"

    // MARK: - Updates

    static let checkForUpdates = "checkForUpdates"
    static let checking = "checking"
    static let upToDate = "upToDate"
    static let downloadUpdate = "downloadUpdate"
    static let downloading = "downloading"
    static let extracting = "extracting"
    static let installAndRelaunch = "installAndRelaunch"
    static let installing = "installing"
    static let updateFailed = "updateFailed"
    static let retry = "retry"

    // MARK: - Accessibility

    static let accessibility = "accessibility"
    static let on = "on"
    static let off = "off"
    static let enable = "enable"

    // MARK: - Screen Settings

    static let screen = "screen"
    static let automatic = "automatic"
    static let builtIn = "builtIn"
    static let main = "main"

    // MARK: - Sound Settings

    static let notificationSound = "notificationSound"
    static let none = "none"

    // MARK: - Claude Directory

    static let claudeDirectory = "claudeDirectory"
    static let autoDetect = "autoDetect"
    static let chooseFolder = "chooseFolder"

    // MARK: - Session Status

    static let processing = "processing"
    static let compacting = "compacting"
    static let ready = "ready"
    static let waitingForApproval = "waitingForApproval"
    static let idle = "idle"
    static let ended = "ended"

    // MARK: - Session List

    static let noSessions = "noSessions"
    static let runClaudeInTerminal = "runClaudeInTerminal"
    static let needsYourInput = "needsYourInput"
    static let you = "you"

    // MARK: - Approval Buttons

    static let allow = "allow"
    static let deny = "deny"

    // MARK: - Terminal

    static let terminal = "terminal"
    static let goToTerminal = "goToTerminal"

    // MARK: - Chat View

    static let loadingMessages = "loadingMessages"
    static let noMessagesYet = "noMessagesYet"
    static let interrupted = "interrupted"
    static let claudeNeedsInput = "claudeNeedsInput"
    static let image = "image"
    static let moreToolUses = "moreToolUses"
    static let subagentUsedTools = "subagentUsedTools"
    static let times = "times"

    // MARK: - Tool Results

    static let userModified = "userModified"
    static let stderr = "stderr"
    static let noContent = "noContent"
    static let noMatchesFound = "noMatchesFound"
    static let filesWithMatches = "filesWithMatches"
    static let noFilesFound = "noFilesFound"
    static let truncated = "truncated"
    static let noResultsFound = "noResultsFound"
    static let moreResults = "moreResults"
    static let status = "status"
    static let exit = "exit"
    static let backgroundTask = "backgroundTask"

    // MARK: - Display Mode

    static let notchMode = "notchMode"
    static let statusBarMode = "statusBarMode"

    // MARK: - App Name

    static let vibeNotch = "vibeNotch"
}