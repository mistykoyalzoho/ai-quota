import Cocoa
import SwiftUI

@MainActor
final class MenubarController: NSObject, NSMenuDelegate {
    static let shared = MenubarController()

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isRefreshing = false

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            PopoverManager.shared.configure(with: button)
        }

        updateTitle()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .unifiedAccountsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .unifiedActiveAccountChanged,
            object: nil
        )

        // Start periodic background refresh every 90s
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }

        // Initial fetch
        Task { @MainActor in
            await self.refreshAll()
        }
    }

    @objc private func handleStateChanged() {
        updateTitle()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            PopoverManager.shared.toggle(relativeTo: sender)
        }
    }

    func updateTitle() {
        guard let button = statusItem?.button else { return }

        let active = UnifiedAccountStore.shared.activeAccount
        let usage = active?.lastUsage

        if let usage {
            let primary = usage.primaryPercent
            let label = usage.primaryLabel

            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let imgName = active?.provider.iconSystemName ?? "gauge.with.needle.fill"
            let img = NSImage(systemSymbolName: imgName, accessibilityDescription: "AI Quota")?
                .withSymbolConfiguration(config)
            button.image = img
            button.imagePosition = .imageLeading

            button.title = " \(primary)% \(label)"
        } else {
            let img = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: "AI Quota")
            button.image = img
            button.title = " AI Quota"
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let store = UnifiedAccountStore.shared

        // Header Item
        let header = NSMenuItem(title: "AI Quota — Multi-Account Desk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Accounts list
        if store.allAccounts.isEmpty {
            let noAcc = NSMenuItem(title: "No accounts connected", action: nil, keyEquivalent: "")
            noAcc.isEnabled = false
            menu.addItem(noAcc)
        } else {
            let section = NSMenuItem(title: "Switch Active Account:", action: nil, keyEquivalent: "")
            section.isEnabled = false
            menu.addItem(section)

            for acc in store.allAccounts {
                let isCurrent = (acc.id == store.activeAccountId)
                let pct = acc.lastUsage != nil ? " (\(acc.lastUsage!.primaryPercent)%)" : ""
                let itemTitle = "\(isCurrent ? "✓ " : "    ")\(acc.displayName) [\(acc.provider.shortName)]\(pct)"
                let item = NSMenuItem(title: itemTitle, action: #selector(switchAccountAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = acc.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Refresh All
        let refItem = NSMenuItem(title: isRefreshing ? "Refreshing…" : "Refresh All Accounts", action: #selector(refreshMenuAction), keyEquivalent: "r")
        refItem.target = self
        refItem.isEnabled = !isRefreshing
        menu.addItem(refItem)

        // Auto-detect CLI
        let autoCli = NSMenuItem(title: "Auto-Detect Local CLI Logins", action: #selector(autoDetectAction), keyEquivalent: "d")
        autoCli.target = self
        menu.addItem(autoCli)

        // Add Account
        let addAcc = NSMenuItem(title: "Add Account…", action: #selector(addAccountAction), keyEquivalent: "n")
        addAcc.target = self
        menu.addItem(addAcc)

        // Manage Accounts
        let manage = NSMenuItem(title: "Manage Accounts & Settings…", action: #selector(manageAction), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit AI Quota", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func switchAccountAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            UnifiedAccountStore.shared.setActiveAccount(id: id)
            updateTitle()
        }
    }

    @objc private func refreshMenuAction() {
        Task { @MainActor in
            await refreshAll()
        }
    }

    @objc private func autoDetectAction() {
        UnifiedAccountStore.shared.autoDetectAndMergeCLI()
        Task { @MainActor in
            await refreshAll()
        }
    }

    @objc private func addAccountAction() {
        AddAccountWindowController.shared.show()
    }

    @objc private func manageAction() {
        ManageAccountsWindowController.shared.show()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let accounts = UnifiedAccountStore.shared.allAccounts
        await UnifiedBillingCoordinator.shared.refreshAll(accounts: accounts)
        isRefreshing = false
        updateTitle()
        PopoverManager.shared.reload()
    }
}
