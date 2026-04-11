//
//  UsageSettingsRow.swift
//  ClaudeIsland
//
//  Usage display settings and per-profile plan configuration for the settings menu.
//

import SwiftUI

struct UsageSettingsRow: View {
    @ObservedObject var usageSettings: UsageSettings
    @State private var isHovered = false

    private var isExpanded: Bool {
        usageSettings.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        usageSettings.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Usage Monitor")
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

            // Expanded settings
            if isExpanded {
                VStack(spacing: 2) {
                    // Display toggles
                    UsageToggleRow(label: "Show Cost", isOn: usageSettings.displayConfig.showCost) {
                        var config = usageSettings.displayConfig
                        config.showCost.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    UsageToggleRow(label: "Show Burn Rate", isOn: usageSettings.displayConfig.showBurnRate) {
                        var config = usageSettings.displayConfig
                        config.showBurnRate.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    UsageToggleRow(label: "Show Savings", isOn: usageSettings.displayConfig.showSavings) {
                        var config = usageSettings.displayConfig
                        config.showSavings.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    UsageToggleRow(label: "Lifetime Savings", isOn: usageSettings.displayConfig.showLifetimeSavings) {
                        var config = usageSettings.displayConfig
                        config.showLifetimeSavings.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.vertical, 4)

                    // Limit bar toggles
                    Text("LIMIT BARS")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(0.6)
                        .padding(.leading, 10)

                    UsageToggleRow(label: "Session (5h)", isOn: usageSettings.displayConfig.showSessionBar) {
                        var config = usageSettings.displayConfig
                        config.showSessionBar.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    UsageToggleRow(label: "Weekly (7d)", isOn: usageSettings.displayConfig.showWeeklyBar) {
                        var config = usageSettings.displayConfig
                        config.showWeeklyBar.toggle()
                        usageSettings.updateDisplayConfig(config)
                    }

                    // Per-profile plan pickers
                    if !usageSettings.profilePlans.isEmpty {
                        Divider()
                            .background(Color.white.opacity(0.06))
                            .padding(.vertical, 4)

                        ForEach(Array(usageSettings.profilePlans.keys.sorted()), id: \.self) { profile in
                            PlanPickerRow(
                                profile: profile,
                                currentPlan: usageSettings.profilePlans[profile] ?? .pro
                            ) { newPlan in
                                usageSettings.setPlan(newPlan, for: profile)
                            }
                        }
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
}

// MARK: - Usage Toggle Row

private struct UsageToggleRow: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(isOn ? TerminalColors.green : .white.opacity(0.3))

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Plan Picker Row

private struct PlanPickerRow: View {
    let profile: String
    let currentPlan: PlanType
    let onSelect: (PlanType) -> Void

    @State private var isExpanded = false
    @State private var isHovered = false

    private let plans: [PlanType] = [.pro, .max5x, .max20x, .team]

    var body: some View {
        VStack(spacing: 2) {
            // Profile label + current plan
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(profile.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Spacer()

                    Text(currentPlan.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Plan options
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(plans, id: \.displayName) { plan in
                        PlanOptionRow(plan: plan, isSelected: currentPlan == plan) {
                            onSelect(plan)
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded = false
                            }
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
}

// MARK: - Plan Option Row

private struct PlanOptionRow: View {
    let plan: PlanType
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(plan.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Text("$\(Int(plan.monthlyFee))/mo")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
