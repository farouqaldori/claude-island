//
//  LocalizationManager.swift
//  ClaudeIsland
//
//  Manages app language and provides localized strings
//

import Combine
import Foundation
import SwiftUI

/// Supported app languages
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    var icon: String {
        switch self {
        case .english: return "globe"
        case .chinese: return "character"
        }
    }
}

/// Manages app language settings and provides localized strings
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let languageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    // Localized strings dictionary
    private let strings: [AppLanguage: [String: String]] = [
        .english: englishStrings,
        .chinese: chineseStrings
    ]

    private init() {
        // Load saved language or default to Chinese
        if let saved = UserDefaults.standard.string(forKey: Self.languageKey),
           let lang = AppLanguage(rawValue: saved) {
            language = lang
        } else {
            language = .chinese
        }
    }

    /// Change app language
    func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
    }

    /// Get localized string for a key
    func localizedString(for key: String) -> String {
        if let langStrings = strings[language],
           let value = langStrings[key] {
            return value
        }
        // Fallback to English
        if let enStrings = strings[.english],
           let value = enStrings[key] {
            return value
        }
        // Final fallback: return the key itself
        return key
    }

    /// Get localized string with format arguments
    func localizedString(for key: String, args: CVarArg...) -> String {
        let template = localizedString(for: key)
        return String(format: template, arguments: args)
    }
}

// MARK: - String Extension for Easy Localization

extension String {
    /// Get localized version of this string key
    var localized: String {
        LocalizationManager.shared.localizedString(for: self)
    }

    /// Get localized string with format arguments
    func localized(with args: CVarArg...) -> String {
        LocalizationManager.shared.localizedString(for: self, args: args)
    }
}

// MARK: - English Strings

private let englishStrings: [String: String] = [
    // Navigation
    "back": "Back",

    // Settings Menu
    "displayMode": "Display Mode",
    "launchAtLogin": "Launch at Login",
    "hooks": "Hooks",
    "starOnGitHub": "Star on GitHub",
    "quit": "Quit",

    // Language
    "language": "Language",

    // Updates
    "checkForUpdates": "Check for Updates",
    "checking": "Checking...",
    "upToDate": "Up to date",
    "downloadUpdate": "Download Update",
    "downloading": "Downloading...",
    "extracting": "Extracting...",
    "installAndRelaunch": "Install & Relaunch",
    "installing": "Installing...",
    "updateFailed": "Update failed",
    "retry": "Retry",

    // Accessibility
    "accessibility": "Accessibility",
    "on": "On",
    "off": "Off",
    "enable": "Enable",

    // Screen Settings
    "screen": "Screen",
    "automatic": "Automatic",
    "builtIn": "Built-in",
    "main": "Main",

    // Sound Settings
    "notificationSound": "Notification Sound",
    "none": "None",

    // Claude Directory
    "claudeDirectory": "Claude Directory",
    "autoDetect": "Auto-detect",
    "chooseFolder": "Choose folder…",

    // Session Status
    "processing": "Processing...",
    "compacting": "Compacting...",
    "ready": "Ready",
    "waitingForApproval": "Waiting for approval",
    "idle": "Idle",
    "ended": "Ended",

    // Session List
    "noSessions": "No sessions",
    "runClaudeInTerminal": "Run claude in terminal",
    "needsYourInput": "Needs your input",
    "you": "You",

    // Approval Buttons
    "allow": "Allow",
    "deny": "Deny",

    // Terminal
    "terminal": "Terminal",
    "goToTerminal": "Go to Terminal",

    // Chat View
    "loadingMessages": "Loading messages...",
    "noMessagesYet": "No messages yet",
    "interrupted": "Interrupted",
    "claudeNeedsInput": "Claude Code needs your input",
    "image": "Image",
    "moreToolUses": "+%d more tool uses",
    "subagentUsedTools": "Subagent used %d tools:",
    "times": "×%d",

    // Tool Results
    "userModified": "(User modified)",
    "stderr": "stderr:",
    "noContent": "(No content)",
    "noMatchesFound": "No matches found",
    "filesWithMatches": "%d files with matches",
    "noFilesFound": "No files found",
    "truncated": "... and more (truncated)",
    "noResultsFound": "No results found",
    "moreResults": "... and %d more results",
    "status": "Status",
    "exit": "Exit",
    "backgroundTask": "Background task: %s",

    // Display Mode
    "notchMode": "Notch",
    "statusBarMode": "StatusBar",

    // App Name
    "vibeNotch": "Vibe Notch",

    // Notifications
    "taskComplete": "Task Complete",
    "claudeReadyForInput": "Claude Code is ready for your input",
    "permissionRequired": "Permission Required",
    "needsYourApproval": "needs your approval",

    // Notification Test
    "notificationTest": "Test Notification",
    "testNotificationSent": "Test notification sent"
]

// MARK: - Chinese Strings

private let chineseStrings: [String: String] = [
    // Navigation
    "back": "返回",

    // Settings Menu
    "displayMode": "显示模式",
    "launchAtLogin": "登录时启动",
    "hooks": "Hooks",
    "starOnGitHub": "在 GitHub 上点赞",
    "quit": "退出",

    // Language
    "language": "语言",

    // Updates
    "checkForUpdates": "检查更新",
    "checking": "检查中...",
    "upToDate": "已是最新",
    "downloadUpdate": "下载更新",
    "downloading": "下载中...",
    "extracting": "解压中...",
    "installAndRelaunch": "安装并重启",
    "installing": "安装中...",
    "updateFailed": "更新失败",
    "retry": "重试",

    // Accessibility
    "accessibility": "辅助功能",
    "on": "开",
    "off": "关",
    "enable": "启用",

    // Screen Settings
    "screen": "屏幕",
    "automatic": "自动",
    "builtIn": "内置",
    "main": "主显示器",

    // Sound Settings
    "notificationSound": "通知音效",
    "none": "无",

    // Claude Directory
    "claudeDirectory": "Claude 目录",
    "autoDetect": "自动检测",
    "chooseFolder": "选择文件夹…",

    // Session Status
    "processing": "处理中",
    "compacting": "压缩中",
    "ready": "就绪",
    "waitingForApproval": "等待批准",
    "idle": "空闲",
    "ended": "已结束",

    // Session List
    "noSessions": "无会话",
    "runClaudeInTerminal": "在终端运行 claude",
    "needsYourInput": "需要输入",
    "you": "你",

    // Approval Buttons
    "allow": "允许",
    "deny": "拒绝",

    // Terminal
    "terminal": "终端",
    "goToTerminal": "前往终端",

    // Chat View
    "loadingMessages": "加载消息中...",
    "noMessagesYet": "暂无消息",
    "interrupted": "已中断",
    "claudeNeedsInput": "Claude Code 需要输入",
    "image": "图片",
    "moreToolUses": "+%d 个工具调用",
    "subagentUsedTools": "子代理使用了 %d 个工具：",
    "times": "×%d",

    // Tool Results
    "userModified": "(用户已修改)",
    "stderr": "标准错误输出：",
    "noContent": "(无内容)",
    "noMatchesFound": "未找到匹配项",
    "filesWithMatches": "%d 个文件有匹配",
    "noFilesFound": "未找到文件",
    "truncated": "... 更多内容已截断",
    "noResultsFound": "未找到结果",
    "moreResults": "... 还有 %d 个结果",
    "status": "状态",
    "exit": "退出码",
    "backgroundTask": "后台任务：%s",

    // Display Mode
    "notchMode": "刘海屏",
    "statusBarMode": "状态栏",

    // App Name
    "vibeNotch": "Vibe Notch",

    // Notifications
    "taskComplete": "任务完成",
    "claudeReadyForInput": "Claude Code 已准备好接收输入",
    "permissionRequired": "需要权限批准",
    "needsYourApproval": "需要您的批准",

    // Notification Test
    "notificationTest": "测试通知",
    "testNotificationSent": "测试通知已发送"
]