import SwiftUI
import AppKit

final class UnifiedPopoverViewModel: ObservableObject {
    @Published var accounts: [UnifiedAccount] = []
    @Published var activeAccountId: String?
    @Published var selectedProviderFilter: AIProvider? = nil // nil = All
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshedAt: Date? = Date()
    @Published var errorMessage: String? = nil

    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let accountsObserver = NotificationCenter.default.addObserver(
            forName: .unifiedAccountsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        let activeObserver = NotificationCenter.default.addObserver(
            forName: .unifiedActiveAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        observers = [accountsObserver, activeObserver]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        self.accounts = UnifiedAccountStore.shared.allAccounts
        self.activeAccountId = UnifiedAccountStore.shared.activeAccountId
        if let activeId = activeAccountId,
           let activeErr = accounts.first(where: { $0.id == activeId })?.lastError {
            self.errorMessage = activeErr
        } else if let err = accounts.compactMap(\.lastError).first {
            self.errorMessage = err
        } else {
            self.errorMessage = nil
        }
    }

    var filteredAccounts: [UnifiedAccount] {
        if let filter = selectedProviderFilter {
            return accounts.filter { $0.provider == filter }
        }
        return accounts
    }

    func selectActiveAccount(_ id: String) {
        UnifiedAccountStore.shared.setActiveAccount(id: id)
        reload()
    }

    func refreshAccount(_ id: String) {
        guard let acc = accounts.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            self.isRefreshing = true
            _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true)
            self.lastRefreshedAt = Date()
            self.isRefreshing = false
            self.reload()
        }
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            self.isRefreshing = true
            await UnifiedBillingCoordinator.shared.refreshAll(accounts: self.accounts)
            self.lastRefreshedAt = Date()
            self.isRefreshing = false
            self.reload()
        }
    }

    func autoDetectCLI() {
        UnifiedAccountStore.shared.autoDetectAndMergeCLI()
        reload()
        refreshAll()
    }
}

// MARK: - Unified Popover View

struct UnifiedPopoverView: View {
    @ObservedObject var viewModel: UnifiedPopoverViewModel
    var onOpenAddAccount: () -> Void
    var onOpenManageAccounts: () -> Void
    var onQuit: () -> Void

    private var popoverWidth: CGFloat {
        let count = viewModel.filteredAccounts.count
        switch count {
        case 0, 1: return 280
        case 2: return 460
        case 3: return 660
        default: return min(CGFloat(count) * 210 + 30, 720)
        }
    }

    var body: some View {
        Group {
            if viewModel.accounts.isEmpty {
                emptyLandingView
            } else {
                mainDashboardContent
            }
        }
        .frame(width: popoverWidth)
        .background(popoverSurface)
    }

    @ViewBuilder
    private var popoverSurface: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Color(nsColor: .windowBackgroundColor).opacity(0.92)
            }
    }

    // MARK: - Main Dashboard

    private var mainDashboardContent: some View {
        VStack(spacing: 0) {
            header
            filterBar

            if let err = viewModel.errorMessage {
                errorBanner(err)
                Divider()
            }

            // Visual Overlays / Gauges Row
            if viewModel.filteredAccounts.count <= 3 {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(viewModel.filteredAccounts.enumerated()), id: \.element.id) { index, account in
                        accountGaugeCard(account)
                            .frame(maxWidth: .infinity)
                        if index < viewModel.filteredAccounts.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(viewModel.filteredAccounts.enumerated()), id: \.element.id) { index, account in
                            accountGaugeCard(account)
                                .frame(width: 210)
                            if index < viewModel.filteredAccounts.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
            }

            Divider()

            // Details & Breakdown Stats
            detailedStatsSection

            Divider()

            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.gaugeAccent)

            Text("AI Quota")
                .font(.headline.bold())

            Spacer()

            // Legend
            HStack(spacing: 8) {
                legendItem(label: "Primary", opacity: 1.0)
                legendItem(label: "Secondary", opacity: 0.5)
            }

            // Auto-detect CLI button
            Button(action: { viewModel.autoDetectCLI() }) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Auto-detect local Codex, Claude, Grok, Cursor, Copilot, Command Code, & OpenCode Go logins")

            // Add Account button
            Button(action: onOpenAddAccount) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Add another AI account")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func legendItem(label: String, opacity: Double) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.gaugeAccent.opacity(opacity))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.gaugeAccent.opacity(opacity))
        }
    }

    // MARK: - Provider Filter Bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterButton(title: "All (\(viewModel.accounts.count))", provider: nil)

                    ForEach(AIProvider.allCases) { prov in
                        let count = viewModel.accounts.filter { $0.provider == prov }.count
                        if count > 0 {
                            filterButton(title: "\(prov.shortName) (\(count))", provider: prov)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: { viewModel.refreshAll() }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                    Text("Refresh")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func filterButton(title: String, provider: AIProvider?) -> some View {
        let isSelected = (viewModel.selectedProviderFilter == provider)
        return Button(action: { viewModel.selectedProviderFilter = provider }) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Account Gauge Card

    @ViewBuilder
    private func accountGaugeCard(_ account: UnifiedAccount) -> some View {
        let usage = account.lastUsage
        let primaryVal = usage?.primaryPercent ?? 0
        let secondaryVal = usage?.secondaryPercent ?? 0
        let isActive = (account.id == viewModel.activeAccountId)

        VStack(spacing: 6) {
            // Active Switcher & Provider Badge
            HStack(spacing: 4) {
                // Provider tag
                HStack(spacing: 3) {
                    Image(systemName: account.provider.iconSystemName)
                        .font(.system(size: 8))
                    Text(account.provider.shortName)
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(account.provider.primaryAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(account.provider.primaryAccent.opacity(0.12)))

                Spacer()

                // Set Active button
                Button(action: { viewModel.selectActiveAccount(account.id) }) {
                    HStack(spacing: 2) {
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("ACTIVE")
                                .font(.system(size: 8.5, weight: .bold))
                        } else {
                            Text("SET ACTIVE")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(isActive ? Color.gaugeAccent : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isActive ? Color.gaugeAccent.opacity(0.15) : Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            // Circular Gauge
            CircularGaugeView(
                provider: account.provider,
                primaryPercent: primaryVal,
                primaryLimitReached: usage?.primaryLimitReached ?? false,
                showsPrimaryMetric: usage != nil,
                secondaryPercent: secondaryVal,
                secondaryLimitReached: usage?.secondaryLimitReached ?? false,
                showsSecondaryMetric: usage?.secondaryPercent != nil,
                isLoading: account.lastUsage == nil && account.lastError == nil,
                label: account.displayName,
                primaryLabel: usage?.primaryLabel ?? account.provider.defaultPrimaryLabel,
                secondaryLabel: usage?.secondaryLabel ?? account.provider.defaultSecondaryLabel,
                resetAt: usage?.primaryResetsAt,
                weeklyResetAt: usage?.secondaryResetsAt,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: { viewModel.refreshAccount(account.id) }
            )
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Detailed Stats Section

    private var detailedStatsSection: some View {
        VStack(spacing: 6) {
            if viewModel.filteredAccounts.count <= 3 {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(viewModel.filteredAccounts.enumerated()), id: \.element.id) { index, account in
                        accountStatsColumn(account)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index < viewModel.filteredAccounts.count - 1 {
                            Divider()
                        }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(viewModel.filteredAccounts.enumerated()), id: \.element.id) { index, account in
                            accountStatsColumn(account)
                                .padding(.horizontal, 10)
                                .frame(width: 210, alignment: .leading)
                            if index < viewModel.filteredAccounts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func accountStatsColumn(_ account: UnifiedAccount) -> some View {
        let usage = account.lastUsage
        let tier = usage?.planTier ?? (account.isFreePlan ? "Free Plan" : "Active Plan")

        VStack(alignment: .leading, spacing: 4) {
            // Plan Tier Row
            HStack {
                Text("Plan:")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tier)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(account.isFreePlan ? Color.warningAmber : Color.primary)
            }

            // Extra Usage / Credits if available
            if let spent = usage?.extraUsageSpent {
                HStack {
                    Text("Spend:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let limit = usage?.extraUsageLimit {
                        Text(String(format: "$%.2f / $%.2f", spent, limit))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    } else {
                        Text(String(format: "$%.2f", spent))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    }
                }
            }

            // Breakdown Items
            if let items = usage?.breakdownItems, !items.isEmpty {
                VStack(spacing: 2) {
                    ForEach(items.prefix(3)) { item in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(account.provider.primaryAccent.opacity(0.8))
                                .frame(width: 4.5, height: 4.5)
                            Text(item.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.usagePercent)%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: onOpenManageAccounts) {
                Text("Accounts & Settings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if let date = viewModel.lastRefreshedAt {
                Text(dateRelativeText(date))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            Button(role: .destructive, action: onQuit) {
                Text("Quit")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Empty Landing View

    private var emptyLandingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color.gaugeAccent)

            VStack(spacing: 4) {
                Text("AI Quota")
                    .font(.title3.bold())
                Text("Track multi-account quotas for Codex, Claude, SuperGrok, Cursor, Copilot, Command Code, and OpenCode Go.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                Button(action: { viewModel.autoDetectCLI() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Auto-Detect Local CLI Logins")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gaugeAccent.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gaugeAccent, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: onOpenAddAccount) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Connect Account Manually")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Button("Settings", action: onOpenManageAccounts)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.warningAmber)
                .font(.caption)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: { viewModel.refreshAll() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.warningAmber.opacity(0.12))
    }

    private func dateRelativeText(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "Refreshed just now" }
        return "Refreshed \(diff / 60)m ago"
    }
}
