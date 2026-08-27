import Cocoa
import SwiftUI

@MainActor
final class ManageAccountsWindowController: NSObject, NSWindowDelegate {
    static let shared = ManageAccountsWindowController()

    private var window: NSWindow?

    func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ManageAccountsSwiftUIView(
            onClose: { [weak self] in self?.close() },
            onAddAccount: {
                AddAccountWindowController.shared.show()
            }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Manage AI Quota Accounts"
        win.contentView = NSHostingView(rootView: contentView)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Manage Accounts SwiftUI View

private struct ManageAccountsSwiftUIView: View {
    var onClose: () -> Void
    var onAddAccount: () -> Void

    @State private var accounts: [UnifiedAccount] = UnifiedAccountStore.shared.allAccounts
    @State private var activeAccountId: String? = UnifiedAccountStore.shared.activeAccountId

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts & Providers")
                        .font(.title3.bold())
                    Text("Manage connected accounts for all supported AI providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAddAccount) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Account")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }

            Divider()

            // Accounts List
            if accounts.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No connected accounts")
                        .font(.headline)
                    Text("Click 'Auto-Detect Local CLI' or 'Add Account' to begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(accounts) { acc in
                        accountRow(acc)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Button("Auto-Detect Local CLI Logins") {
                    UnifiedAccountStore.shared.autoDetectAndMergeCLI()
                    refreshLocalState()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.gaugeAccent)

                Spacer()

                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .unifiedAccountsChanged)) { _ in
            refreshLocalState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .unifiedActiveAccountChanged)) { _ in
            refreshLocalState()
        }
    }

    private func refreshLocalState() {
        self.accounts = UnifiedAccountStore.shared.allAccounts
        self.activeAccountId = UnifiedAccountStore.shared.activeAccountId
    }

    @ViewBuilder
    private func accountRow(_ acc: UnifiedAccount) -> some View {
        let isActive = (acc.id == activeAccountId)
        let usage = acc.lastUsage

        HStack(spacing: 12) {
            // Provider Icon
            Image(systemName: acc.provider.iconSystemName)
                .font(.system(size: 18))
                .foregroundStyle(acc.provider.primaryAccent)
                .frame(width: 24)

            // Account Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(acc.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.gaugeAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.gaugeAccent.opacity(0.12)))
                    }
                }

                HStack(spacing: 8) {
                    Text(acc.provider.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let tier = usage?.planTier {
                        Text("•  \(tier)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let used = usage?.primaryPercent {
                        Text("•  \(used)% used")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(used >= 85 ? Color.warningAmber : Color.primary)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 6) {
                if !isActive {
                    Button("Set Active") {
                        UnifiedAccountStore.shared.setActiveAccount(id: acc.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(role: .destructive) {
                    UnifiedAccountStore.shared.removeAccount(id: acc.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
