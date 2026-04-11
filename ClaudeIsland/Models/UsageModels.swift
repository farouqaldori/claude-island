//
//  UsageModels.swift
//  ClaudeIsland
//
//  Data models for usage monitoring, cost estimation, and plan configuration.
//

import Foundation

// MARK: - Claude Model

/// Normalized Claude model family for pricing lookups
enum ClaudeModel: String, Sendable, Equatable, Codable, CaseIterable {
    case opus
    case sonnet
    case haiku
    case unknown

    /// Normalize an API model name to a model family using prefix matching
    static func from(apiModelName: String) -> ClaudeModel {
        let name = apiModelName.lowercased()
        if name.contains("opus") { return .opus }
        if name.contains("sonnet") { return .sonnet }
        if name.contains("haiku") { return .haiku }
        return .unknown
    }
}

// MARK: - Model Pricing

/// Per-million-token pricing for a Claude model family
struct ModelPricing: Sendable, Equatable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheCreatePerMillion: Double
    let cacheReadPerMillion: Double

    static let opus = ModelPricing(
        inputPerMillion: 15.0,
        outputPerMillion: 75.0,
        cacheCreatePerMillion: 18.75,
        cacheReadPerMillion: 1.50
    )

    static let sonnet = ModelPricing(
        inputPerMillion: 3.0,
        outputPerMillion: 15.0,
        cacheCreatePerMillion: 3.75,
        cacheReadPerMillion: 0.30
    )

    static let haiku = ModelPricing(
        inputPerMillion: 0.25,
        outputPerMillion: 1.25,
        cacheCreatePerMillion: 0.30,
        cacheReadPerMillion: 0.03
    )

    /// Get pricing for a model family. Unknown models use Sonnet pricing as a reasonable default.
    static func pricing(for model: ClaudeModel) -> ModelPricing {
        switch model {
        case .opus: return .opus
        case .sonnet: return .sonnet
        case .haiku: return .haiku
        case .unknown: return .sonnet
        }
    }
}

// MARK: - Plan Type

/// Claude subscription plan type
enum PlanType: Sendable, Equatable, Codable {
    case pro
    case max5x
    case max20x
    case team
    case enterprise

    var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5x"
        case .max20x: return "Max 20x"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        }
    }

    var monthlyFee: Double {
        switch self {
        case .pro: return 20.0
        case .max5x: return 100.0
        case .max20x: return 200.0
        case .team: return 100.0
        case .enterprise: return 0.0  // Custom pricing
        }
    }

    /// Session cost limit (USD) per 5-hour window
    /// From claude-monitor's observed plan limits. Rate-limit cost excludes cache_read tokens.
    var sessionCostLimit: Double {
        switch self {
        case .pro: return 18.0
        case .max5x: return 35.0
        case .max20x: return 140.0
        case .team: return 35.0      // Team with max_5x tier uses same limit
        case .enterprise: return 140.0
        }
    }

}

// MARK: - Token Breakdown

/// Token counts broken down by type, used for per-model tracking
struct TokenBreakdown: Sendable, Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreation: Int

    var total: Int { input + output + cacheRead + cacheCreation }

    static let zero = TokenBreakdown(input: 0, output: 0, cacheRead: 0, cacheCreation: 0)

    /// Calculate full API cost using the given pricing
    func cost(using pricing: ModelPricing) -> Double {
        (Double(input) / 1_000_000) * pricing.inputPerMillion
            + (Double(output) / 1_000_000) * pricing.outputPerMillion
            + (Double(cacheCreation) / 1_000_000) * pricing.cacheCreatePerMillion
            + (Double(cacheRead) / 1_000_000) * pricing.cacheReadPerMillion
    }

    /// Calculate rate-limit cost (excludes cache_read tokens, which Anthropic
    /// does not count toward subscription rate limits)
    func rateLimitCost(using pricing: ModelPricing) -> Double {
        (Double(input) / 1_000_000) * pricing.inputPerMillion
            + (Double(output) / 1_000_000) * pricing.outputPerMillion
            + (Double(cacheCreation) / 1_000_000) * pricing.cacheCreatePerMillion
    }

    mutating func add(_ other: TokenBreakdown) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheCreation += other.cacheCreation
    }
}

// MARK: - Burn Rate

/// Token consumption rate for a profile's 5-hour window
struct BurnRate: Sendable, Equatable {
    let tokensPerMinute: Double
    let costPerHour: Double
    let windowElapsedMinutes: Double

    /// Utilization as a fraction (0.0-1.0+) of plan output token limit
    let utilizationPercent: Double

    /// Color tier based on utilization
    var tier: UsageTier {
        if utilizationPercent >= 0.9 { return .critical }
        if utilizationPercent >= 0.5 { return .warning }
        return .normal
    }

    static let zero = BurnRate(
        tokensPerMinute: 0, costPerHour: 0,
        windowElapsedMinutes: 0, utilizationPercent: 0
    )
}

/// Usage severity tier for color coding
enum UsageTier: Sendable, Equatable {
    case normal   // green, < 50%
    case warning  // amber, 50-90%
    case critical // red, >= 90%
}

// MARK: - Cost Estimate

/// Aggregated cost estimates for a profile
struct CostEstimate: Sendable, Equatable {
    let windowCost: Double         // 5h rolling window (full API cost for display)
    let windowRateLimitCost: Double // 5h window excluding cache_read (for limit bars)
    let dailyCost: Double          // Today
    let monthlyCost: Double        // This calendar month
    let monthlySavings: Double     // API cost - subscription fee (negative = losing money)

    /// Formatted window cost
    var formattedWindowCost: String {
        String(format: "$%.2f", windowCost)
    }

    /// Formatted monthly cost
    var formattedMonthlyCost: String {
        String(format: "$%.2f", monthlyCost)
    }

    /// Formatted savings (only meaningful when positive)
    var formattedSavings: String {
        String(format: "$%.0f", max(0, monthlySavings))
    }

    static let zero = CostEstimate(
        windowCost: 0, windowRateLimitCost: 0,
        dailyCost: 0, monthlyCost: 0, monthlySavings: 0
    )
}

// MARK: - Usage Display Config

/// User preferences for what usage info to show in profile headers
struct UsageDisplayConfig: Sendable, Equatable, Codable {
    var showCost: Bool
    var showBurnRate: Bool
    var showSavings: Bool
    var showLifetimeSavings: Bool
    var showSessionBar: Bool
    var showWeeklyBar: Bool

    static let defaults = UsageDisplayConfig(
        showCost: true, showBurnRate: true, showSavings: false,
        showLifetimeSavings: true, showSessionBar: true,
        showWeeklyBar: true
    )
}

// MARK: - Period Usage

/// Aggregated usage for a calendar period (day or month)
struct PeriodUsage: Sendable, Equatable, Identifiable {
    let id: String          // Period key (e.g., "2026-04-10" or "2026-04")
    let label: String       // Display label
    let tokens: TokenBreakdown
    let cost: Double
    let messageCount: Int
    let models: Set<String> // Model families used
}

// MARK: - Lifetime Savings

/// Lifetime savings data for a profile
struct LifetimeSavings: Sendable, Equatable {
    let totalAPICost: Double         // What it would have cost on API pricing
    let totalSubscriptionCost: Double // What was paid in subscription fees
    let monthsSubscribed: Int
    let subscribedSince: Date?

    var savings: Double { totalAPICost - totalSubscriptionCost }

    var formattedSavings: String {
        String(format: "$%.0f", max(0, savings))
    }

    var formattedAPICost: String {
        let cost = totalAPICost
        if cost >= 1000 {
            return String(format: "$%.1fK", cost / 1000)
        }
        return String(format: "$%.0f", cost)
    }

    var sinceLabel: String {
        guard let date = subscribedSince else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Usage Limit Info

/// A single usage limit bar's data, with percentage from Anthropic's backend
struct UsageLimitInfo: Sendable, Equatable, Identifiable {
    let id: String              // "session" or "weekly"
    let label: String           // Display label
    let usedPercentage: Double  // 0-100, from Anthropic's rate_limits API
    let resetsAt: Date?         // When this window resets

    var fraction: Double {
        min(usedPercentage / 100.0, 1.0)
    }

    var percentage: Int {
        Int(usedPercentage.rounded())
    }

    var tier: UsageTier {
        if fraction >= 0.9 { return .critical }
        if fraction >= 0.5 { return .warning }
        return .normal
    }

    var resetLabel: String {
        guard let resetsAt = resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "" }
        let hours = Int(remaining / 3600)
        let mins = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - Rate Limits State (from Anthropic's status line API)

/// Rate limit data read from ~/.claude-island/{profile}.json
/// Written by the statusline script, sourced from Claude Code's rate_limits
struct RateLimitsState: Sendable, Equatable {
    let fiveHourUsedPercentage: Double?
    let fiveHourResetsAt: Date?
    let sevenDayUsedPercentage: Double?
    let sevenDayResetsAt: Date?
    let timestamp: Date
}
