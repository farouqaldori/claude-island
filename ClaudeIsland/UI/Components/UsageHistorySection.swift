//
//  UsageHistorySection.swift
//  ClaudeIsland
//
//  Collapsible daily/monthly cost history section for the settings menu.
//

import SwiftUI

struct UsageHistorySection: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var dailyUsage: [String: [PeriodUsage]] = [:]
    @State private var monthlyUsage: [String: [PeriodUsage]] = [:]
    @State private var lifetimeSavings: [String: LifetimeSavings] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    if isExpanded { loadData() }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Usage History")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded content
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(Array(sessionMonitor.profileUsage.keys.sorted()), id: \.self) { profile in
                        ProfileHistoryCard(
                            profile: profile,
                            daily: dailyUsage[profile] ?? [],
                            monthly: monthlyUsage[profile] ?? [],
                            lifetime: lifetimeSavings[profile],
                            plan: UsageSettings.shared.getPlan(for: profile)
                        )
                    }

                    if sessionMonitor.profileUsage.isEmpty {
                        Text("No usage data")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.vertical, 8)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func loadData() {
        Task {
            let settings = UsageSettings.shared
            for profile in sessionMonitor.profileUsage.keys {
                let extended = await UsageTracker.shared.getExtendedUsage(for: profile)
                dailyUsage[profile] = extended.daily
                monthlyUsage[profile] = extended.monthly

                // Calculate lifetime savings
                let plan = settings.getPlan(for: profile)
                let totalAPICost = await UsageTracker.shared.getLifetimeCost(for: profile)

                let configDir = UsageTracker.configDir(for: profile)

                let subStart = UsageTracker.getSubscriptionStartDate(configDir: configDir)
                let months: Int
                if let start = subStart {
                    let components = Calendar.current.dateComponents([.month], from: start, to: Date())
                    months = max(1, (components.month ?? 1))
                } else {
                    months = 1
                }

                lifetimeSavings[profile] = LifetimeSavings(
                    totalAPICost: totalAPICost,
                    totalSubscriptionCost: plan.monthlyFee * Double(months),
                    monthsSubscribed: months,
                    subscribedSince: subStart
                )
            }
        }
    }
}

// MARK: - Profile History Card

private struct ProfileHistoryCard: View {
    let profile: String
    let daily: [PeriodUsage]
    let monthly: [PeriodUsage]
    let lifetime: LifetimeSavings?
    let plan: PlanType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Profile header
            Text(profile.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .tracking(0.6)

            // Today
            if let today = daily.first {
                CostRow(label: "Today", cost: today.cost, tokens: today.tokens.total)
            }

            // This month
            if let month = monthly.first {
                CostRow(label: monthLabel(month.label), cost: month.cost, tokens: month.tokens.total)
            }

            // Previous days (last 3)
            if daily.count > 1 {
                Divider()
                    .background(Color.white.opacity(0.06))

                ForEach(daily.dropFirst().prefix(3)) { day in
                    CostRow(label: day.label, cost: day.cost, tokens: day.tokens.total)
                }
            }

            // Lifetime savings
            if let lt = lifetime, lt.savings > 0 {
                Divider()
                    .background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Lifetime")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))

                        Spacer()

                        Text(lt.formattedSavings)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(TerminalColors.green.opacity(0.7))

                        Text("saved")
                            .font(.system(size: 10))
                            .foregroundColor(TerminalColors.green.opacity(0.4))
                    }

                    HStack(spacing: 4) {
                        Text("\(lt.formattedAPICost) API cost")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))

                        Text("·")
                            .foregroundColor(.white.opacity(0.15))

                        Text("\(lt.monthsSubscribed)mo since \(lt.sinceLabel)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return month < months.count ? months[month] : key
    }
}

// MARK: - Cost Row

private struct CostRow: View {
    let label: String
    let cost: Double
    let tokens: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Spacer()

            Text(ProfileUsage.formatTokenCount(tokens))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))

            Text(String(format: "$%.2f", cost))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}
