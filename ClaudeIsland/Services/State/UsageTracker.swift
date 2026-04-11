//
//  UsageTracker.swift
//  ClaudeIsland
//
//  Tracks token usage per profile by reading Claude Code's local JSONL files.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Usage")

/// Aggregated usage data for a profile
struct ProfileUsage: Equatable, Sendable {
    let profile: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let messageCount: Int
    let lastUpdated: Date
    let windowStartDate: Date?
    let modelBreakdown: [String: TokenBreakdown]

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Formatted total tokens for display (e.g., "1.2M", "450K")
    var formattedTotal: String {
        Self.formatTokenCount(totalTokens)
    }

    /// Formatted output tokens for display
    var formattedOutput: String {
        Self.formatTokenCount(outputTokens)
    }

    static func formatTokenCount(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", value / 1_000)
        }
        return "\(count)"
    }

    static let empty = ProfileUsage(
        profile: "", inputTokens: 0, outputTokens: 0,
        cacheReadTokens: 0, cacheCreationTokens: 0,
        messageCount: 0, lastUpdated: Date(),
        windowStartDate: nil, modelBreakdown: [:]
    )
}

/// Tracks token usage across Claude Code profiles by reading local JSONL conversation logs
actor UsageTracker {
    static let shared = UsageTracker()

    /// Profile name -> config directory path
    private var profileDirs: [String: String] = [:]

    /// Cached usage per profile
    private var usage: [String: ProfileUsage] = [:]

    /// Rate limits from Anthropic's status line API (written to ~/.claude-island/)
    private var rateLimits: [String: RateLimitsState] = [:]

    /// State directory for rate limit files
    private let stateDir = NSHomeDirectory() + "/.claude-island"

    /// How far back to look (5-hour rolling window matches Claude's rate limit window)
    private let lookbackInterval: TimeInterval = 5 * 60 * 60

    /// Weekly window (7 days)
    private let weeklyInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Extended usage cache (daily/monthly) with TTL
    private var extendedUsageCache: [String: (data: ExtendedUsage, fetchedAt: Date)] = [:]
    private let extendedCacheTTL: TimeInterval = 300  // 5 minutes

    private init() {}

    /// Resolve the config directory for a profile name
    nonisolated static func configDir(for profile: String) -> String {
        switch profile {
        case "default": return NSHomeDirectory() + "/.claude"
        default: return NSHomeDirectory() + "/.claude-\(profile)"
        }
    }

    // MARK: - Profile Registration

    /// Register a profile's config directory (called when we first see a session with a profile)
    func registerProfile(_ profile: String, configDir: String) {
        guard profileDirs[profile] == nil else { return }
        profileDirs[profile] = configDir
        logger.info("Registered profile '\(profile, privacy: .public)' at \(configDir, privacy: .public)")
        Task { await refreshProfile(profile) }
    }

    /// Register a profile using the conventional directory naming
    func registerProfile(_ profile: String) {
        registerProfile(profile, configDir: Self.configDir(for: profile))
    }

    // MARK: - Usage Queries

    /// Get current usage for a profile
    func getUsage(for profile: String) -> ProfileUsage? {
        return usage[profile]
    }

    /// Get usage for all registered profiles
    func getAllUsage() -> [String: ProfileUsage] {
        return usage
    }

    /// Get rate limits from Anthropic's status line for a profile
    func getRateLimits(for profile: String) -> RateLimitsState? {
        return rateLimits[profile]
    }

    /// Get rate limits for all profiles
    func getAllRateLimits() -> [String: RateLimitsState] {
        return rateLimits
    }

    /// Read rate limit state files written by the statusline script
    func refreshRateLimits() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return }

        for file in files where file.hasSuffix(".json") {
            let profile = String(file.dropLast(5))  // Remove .json
            let path = stateDir + "/" + file

            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let rl = json["rate_limits"] as? [String: Any]
            let fiveHour = rl?["five_hour"] as? [String: Any]
            let sevenDay = rl?["seven_day"] as? [String: Any]

            let fiveHourResets: Date? = (fiveHour?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let sevenDayResets: Date? = (sevenDay?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }

            rateLimits[profile] = RateLimitsState(
                fiveHourUsedPercentage: fiveHour?["used_percentage"] as? Double,
                fiveHourResetsAt: fiveHourResets,
                sevenDayUsedPercentage: sevenDay?["used_percentage"] as? Double,
                sevenDayResetsAt: sevenDayResets,
                timestamp: Date()
            )
        }
    }

    /// Get extended (daily/monthly) usage for a profile
    func getExtendedUsage(for profile: String) async -> ExtendedUsage {
        // Check cache
        if let cached = extendedUsageCache[profile],
           Date().timeIntervalSince(cached.fetchedAt) < extendedCacheTTL {
            return cached.data
        }

        guard let configDir = profileDirs[profile] else {
            return ExtendedUsage(daily: [], monthly: [])
        }

        let extended = parseExtendedUsage(configDir: configDir)
        extendedUsageCache[profile] = (data: extended, fetchedAt: Date())
        return extended
    }

    /// Get lifetime API cost for a profile (all JSONL files, no date cutoff)
    func getLifetimeCost(for profile: String) async -> Double {
        guard let configDir = profileDirs[profile] else { return 0 }

        let projectsDir = configDir + "/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return 0 }

        var seenIds = Set<String>()
        var totalCost = 0.0
        let distantPast = Date.distantPast

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                let result = parseJSONLFile(filePath, cutoff: distantPast, seenIds: &seenIds)
                for (modelName, breakdown) in result.modelBreakdown {
                    let model = ClaudeModel.from(apiModelName: modelName)
                    let pricing = ModelPricing.pricing(for: model)
                    totalCost += breakdown.cost(using: pricing)
                }
            }
        }

        return totalCost
    }

    /// Get subscription start date from .claude.json for a profile
    nonisolated static func getSubscriptionStartDate(configDir: String) -> Date? {
        let configPath = configDir + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let dateStr = account["subscriptionCreatedAt"] as? String else {
            return nil
        }

        // Try with fractional seconds first, then without
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateStr) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateStr)
    }

    // MARK: - Refresh

    /// Refresh usage data for all registered profiles
    func refreshAll() async {
        refreshRateLimits()
        for profile in profileDirs.keys {
            await refreshProfile(profile)
        }
    }

    /// Refresh usage data for a specific profile
    func refreshProfile(_ profile: String) async {
        guard let configDir = profileDirs[profile] else { return }

        let projectsDir = configDir + "/projects"
        let cutoff = Date().addingTimeInterval(-lookbackInterval)

        var totalBreakdown: [String: TokenBreakdown] = [:]
        var messageCount = 0
        var earliestDate: Date?
        var seenIds = Set<String>()

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            logger.debug("No projects dir for profile '\(profile, privacy: .public)'")
            return
        }

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate > cutoff else { continue }

                let result = parseJSONLFile(filePath, cutoff: cutoff, seenIds: &seenIds)
                for (model, breakdown) in result.modelBreakdown {
                    totalBreakdown[model, default: .zero].add(breakdown)
                }
                messageCount += result.messages
                if let date = result.earliestDate {
                    if earliestDate == nil || date < earliestDate! {
                        earliestDate = date
                    }
                }
            }
        }

        // Compute totals from model breakdown
        var totalInput = 0, totalOutput = 0, totalCacheRead = 0, totalCacheCreation = 0
        for (_, breakdown) in totalBreakdown {
            totalInput += breakdown.input
            totalOutput += breakdown.output
            totalCacheRead += breakdown.cacheRead
            totalCacheCreation += breakdown.cacheCreation
        }

        usage[profile] = ProfileUsage(
            profile: profile,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheCreationTokens: totalCacheCreation,
            messageCount: messageCount,
            lastUpdated: Date(),
            windowStartDate: earliestDate,
            modelBreakdown: totalBreakdown
        )

        logger.debug("Profile '\(profile, privacy: .public)': \(messageCount) messages, \(totalInput + totalOutput)+ tokens in last 5h")
    }

    // MARK: - Cost & Burn Rate Calculations

    /// Calculate cost estimate for a profile's usage
    /// dailyCost and monthlyCost come from actual aggregated data when available
    nonisolated static func calculateCost(
        for usage: ProfileUsage,
        plan: PlanType,
        extendedUsage: ExtendedUsage? = nil
    ) -> CostEstimate {
        // Window cost from model breakdown
        var windowCost = 0.0
        var windowRateLimitCost = 0.0
        for (modelName, breakdown) in usage.modelBreakdown {
            let model = ClaudeModel.from(apiModelName: modelName)
            let pricing = ModelPricing.pricing(for: model)
            windowCost += breakdown.cost(using: pricing)
            windowRateLimitCost += breakdown.rateLimitCost(using: pricing)
        }

        // Use actual aggregated data for daily/monthly when available
        let dailyCost = extendedUsage?.daily.first?.cost ?? windowCost
        let monthlyCost = extendedUsage?.monthly.first?.cost ?? windowCost
        let monthlySavings = monthlyCost - plan.monthlyFee

        return CostEstimate(
            windowCost: windowCost,
            windowRateLimitCost: windowRateLimitCost,
            dailyCost: dailyCost,
            monthlyCost: monthlyCost,
            monthlySavings: monthlySavings
        )
    }

    /// Calculate burn rate for a profile's usage
    nonisolated static func calculateBurnRate(for usage: ProfileUsage, plan: PlanType) -> BurnRate {
        guard let windowStart = usage.windowStartDate else {
            return .zero
        }

        let elapsed = Date().timeIntervalSince(windowStart) / 60.0  // minutes
        guard elapsed > 1.0 else { return .zero }

        let tokensPerMinute = Double(usage.outputTokens) / elapsed

        // Cost-based utilization (exclude cache_read for rate limit calculation)
        var windowCost = 0.0
        var rateLimitCost = 0.0
        for (modelName, breakdown) in usage.modelBreakdown {
            let model = ClaudeModel.from(apiModelName: modelName)
            let pricing = ModelPricing.pricing(for: model)
            windowCost += breakdown.cost(using: pricing)
            rateLimitCost += breakdown.rateLimitCost(using: pricing)
        }
        let costPerHour = (windowCost / elapsed) * 60.0
        let utilization = plan.sessionCostLimit > 0 ? rateLimitCost / plan.sessionCostLimit : 0

        return BurnRate(
            tokensPerMinute: tokensPerMinute,
            costPerHour: costPerHour,
            windowElapsedMinutes: elapsed,
            utilizationPercent: utilization
        )
    }

    // MARK: - JSONL Parsing

    private struct ParseResult {
        let modelBreakdown: [String: TokenBreakdown]
        let messages: Int
        let earliestDate: Date?
    }

    /// Parse a single JSONL file for usage data with model tracking and deduplication.
    /// Pass a shared `seenIds` set across files to deduplicate entries that appear in multiple JSONL files.
    private func parseJSONLFile(_ path: String, cutoff: Date, seenIds: inout Set<String>) -> ParseResult {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return ParseResult(modelBreakdown: [:], messages: 0, earliestDate: nil)
        }

        var modelBreakdown: [String: TokenBreakdown] = [:]
        var messages = 0
        var earliestDate: Date?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in content.split(separator: "\n") where line.contains("\"usage\"") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Check timestamp
            if let timestamp = json["timestamp"] as? String {
                guard let date = formatter.date(from: timestamp), date > cutoff else {
                    continue
                }
                if earliestDate == nil || date < earliestDate! {
                    earliestDate = date
                }
            } else {
                continue
            }

            guard let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            // Deduplicate by message_id:request_id (same approach as claude-monitor)
            let msgId = message["id"] as? String ?? ""
            let reqId = json["requestId"] as? String ?? ""
            let dedupKey = "\(msgId):\(reqId)"
            guard !dedupKey.isEmpty, dedupKey != ":", seenIds.insert(dedupKey).inserted else {
                continue
            }

            // Extract model name
            let modelName = message["model"] as? String ?? "unknown"

            let breakdown = TokenBreakdown(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
            )

            modelBreakdown[modelName, default: .zero].add(breakdown)
            messages += 1
        }

        return ParseResult(modelBreakdown: modelBreakdown, messages: messages, earliestDate: earliestDate)
    }

    // MARK: - Extended Usage (Daily/Monthly)

    /// Extended usage data for daily and monthly views
    struct ExtendedUsage: Sendable, Equatable {
        let daily: [PeriodUsage]
        let monthly: [PeriodUsage]
    }

    /// Parse all JSONL files for extended daily/monthly aggregation
    private func parseExtendedUsage(configDir: String) -> ExtendedUsage {
        let projectsDir = configDir + "/projects"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return ExtendedUsage(daily: [], monthly: [])
        }

        // Collect all entries with timestamps
        var dailyAgg: [String: (tokens: [String: TokenBreakdown], messages: Int, models: Set<String>)] = [:]
        var monthlyAgg: [String: (tokens: [String: TokenBreakdown], messages: Int, models: Set<String>)] = [:]
        var seenIds = Set<String>()

        let dateFormatter = DateFormatter()
        let monthFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        monthFormatter.dateFormat = "yyyy-MM"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Only look back 90 days for extended usage
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)

        for projectDir in projectDirs {
            let projectPath = projectsDir + "/" + projectDir
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate > cutoff else { continue }

                guard let data = fm.contents(atPath: filePath),
                      let content = String(data: data, encoding: .utf8) else { continue }

                for line in content.split(separator: "\n") where line.contains("\"usage\"") {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let timestamp = json["timestamp"] as? String,
                          let date = isoFormatter.date(from: timestamp),
                          date > cutoff,
                          let message = json["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else {
                        continue
                    }

                    // Deduplicate
                    let msgId = message["id"] as? String ?? ""
                    let reqId = json["requestId"] as? String ?? ""
                    let dedupKey = "\(msgId):\(reqId)"
                    guard !dedupKey.isEmpty, dedupKey != ":", seenIds.insert(dedupKey).inserted else {
                        continue
                    }

                    let modelName = message["model"] as? String ?? "unknown"
                    let modelFamily = ClaudeModel.from(apiModelName: modelName).rawValue
                    let dayKey = dateFormatter.string(from: date)
                    let monthKey = monthFormatter.string(from: date)

                    let breakdown = TokenBreakdown(
                        input: usage["input_tokens"] as? Int ?? 0,
                        output: usage["output_tokens"] as? Int ?? 0,
                        cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                        cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
                    )

                    // Daily
                    var daily = dailyAgg[dayKey] ?? (tokens: [:], messages: 0, models: [])
                    daily.tokens[modelName, default: .zero].add(breakdown)
                    daily.messages += 1
                    daily.models.insert(modelFamily)
                    dailyAgg[dayKey] = daily

                    // Monthly
                    var monthly = monthlyAgg[monthKey] ?? (tokens: [:], messages: 0, models: [])
                    monthly.tokens[modelName, default: .zero].add(breakdown)
                    monthly.messages += 1
                    monthly.models.insert(modelFamily)
                    monthlyAgg[monthKey] = monthly
                }
            }
        }

        // Convert to PeriodUsage arrays
        let dailyUsage = dailyAgg.map { key, value in
            let totalTokens = value.tokens.values.reduce(TokenBreakdown.zero) { result, b in
                var r = result; r.add(b); return r
            }
            let cost = value.tokens.reduce(0.0) { result, pair in
                let model = ClaudeModel.from(apiModelName: pair.key)
                return result + pair.value.cost(using: ModelPricing.pricing(for: model))
            }
            return PeriodUsage(
                id: key, label: key, tokens: totalTokens,
                cost: cost, messageCount: value.messages, models: value.models
            )
        }.sorted { $0.id > $1.id }  // Most recent first

        let monthlyUsage = monthlyAgg.map { key, value in
            let totalTokens = value.tokens.values.reduce(TokenBreakdown.zero) { result, b in
                var r = result; r.add(b); return r
            }
            let cost = value.tokens.reduce(0.0) { result, pair in
                let model = ClaudeModel.from(apiModelName: pair.key)
                return result + pair.value.cost(using: ModelPricing.pricing(for: model))
            }
            return PeriodUsage(
                id: key, label: key, tokens: totalTokens,
                cost: cost, messageCount: value.messages, models: value.models
            )
        }.sorted { $0.id > $1.id }

        return ExtendedUsage(daily: dailyUsage, monthly: monthlyUsage)
    }
}
