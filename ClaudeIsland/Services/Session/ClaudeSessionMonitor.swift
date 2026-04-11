//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []
    @Published var profileUsage: [String: ProfileUsage] = [:]
    @Published var profileCosts: [String: CostEstimate] = [:]
    @Published var profileBurnRates: [String: BurnRate] = [:]
    @Published var profileLimits: [String: [UsageLimitInfo]] = [:]
    @Published var profileLifetimeSavings: [String: LifetimeSavings] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var usageRefreshTimer: Timer?
    private var lastUsageRefresh: Date = .distantPast
    private let usageRefreshMinInterval: TimeInterval = 30

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self

        // Invalidate lifetime savings cache when plan changes
        NotificationCenter.default.publisher(for: .usagePlanDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let profile = notification.object as? String {
                    self?.profileLifetimeSavings.removeValue(forKey: profile)
                }
            }
            .store(in: &cancellables)

        // Refresh usage data every 60 seconds
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshUsage()
            }
        }
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }

        // Throttle: only refresh usage if enough time has passed since last refresh
        if Date().timeIntervalSince(lastUsageRefresh) >= usageRefreshMinInterval {
            Task { await refreshUsage() }
        }
    }

    func refreshUsage() async {
        lastUsageRefresh = Date()
        await UsageTracker.shared.refreshAll()
        profileUsage = await UsageTracker.shared.getAllUsage()

        // Calculate costs, burn rates, and limit bars per profile
        let settings = UsageSettings.shared
        var costs: [String: CostEstimate] = [:]
        var rates: [String: BurnRate] = [:]
        var limits: [String: [UsageLimitInfo]] = [:]

        for (profile, usage) in profileUsage {
            let plan = settings.getPlan(for: profile)
            let extended = await UsageTracker.shared.getExtendedUsage(for: profile)
            costs[profile] = UsageTracker.calculateCost(for: usage, plan: plan, extendedUsage: extended)
            rates[profile] = UsageTracker.calculateBurnRate(for: usage, plan: plan)

            // Build limit bars from Anthropic's actual rate_limits data
            var bars: [UsageLimitInfo] = []
            let rl = await UsageTracker.shared.getRateLimits(for: profile)

            if let fiveHour = rl?.fiveHourUsedPercentage {
                bars.append(UsageLimitInfo(
                    id: "session",
                    label: "Session",
                    usedPercentage: fiveHour,
                    resetsAt: rl?.fiveHourResetsAt
                ))
            }

            if let sevenDay = rl?.sevenDayUsedPercentage {
                bars.append(UsageLimitInfo(
                    id: "weekly",
                    label: "Weekly",
                    usedPercentage: sevenDay,
                    resetsAt: rl?.sevenDayResetsAt
                ))
            }

            limits[profile] = bars
        }

        profileCosts = costs
        profileBurnRates = rates
        profileLimits = limits

        // Calculate lifetime savings for any profiles we haven't computed yet
        let missingProfiles = profileUsage.keys.filter { profileLifetimeSavings[$0] == nil }
        if !missingProfiles.isEmpty {
            var lt = profileLifetimeSavings
            for profile in missingProfiles {
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
                lt[profile] = LifetimeSavings(
                    totalAPICost: totalAPICost,
                    totalSubscriptionCost: plan.monthlyFee * Double(months),
                    monthsSubscribed: months,
                    subscribedSince: subStart
                )
            }
            profileLifetimeSavings = lt
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
