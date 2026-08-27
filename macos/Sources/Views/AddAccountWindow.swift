import Cocoa
import SwiftUI

@MainActor
final class AddAccountWindowController: NSObject, NSWindowDelegate {
    static let shared = AddAccountWindowController()

    private var window: NSWindow?
    private var webLoginController: WebLoginWindowController?

    func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = AddAccountSwiftUIView(
            onCancel: { [weak self] in self?.close() },
            onConnectWeb: { [weak self] provider, nickname in self?.startWebLogin(provider: provider, nickname: nickname) },
            onConnectCLI: { [weak self] provider, nickname in self?.connectCLI(provider: provider, nickname: nickname) },
            onConnectDeviceCode: { [weak self] in self?.startGrokDeviceAuth() },
            onConnectManualAntigravity: { [weak self] nickname, accessToken, refreshToken, email in
                self?.connectManualAntigravity(nickname: nickname, accessToken: accessToken, refreshToken: refreshToken, email: email)
            }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Connect AI Account"
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

    private func startWebLogin(provider: AIProvider, nickname: String) {
        let controller = WebLoginWindowController(provider: provider, nickname: nickname) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let acc):
                    UnifiedAccountStore.shared.addOrUpdateAccount(acc)
                    Task { _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true) }
                    self?.close()
                case .failure(let err):
                    print("Web login failed:", err.localizedDescription)
                }
            }
        }
        self.webLoginController = controller
        controller.show()
    }

    private func connectCLI(provider: AIProvider, nickname: String) {
        let detected: UnifiedAccount?
        switch provider {
        case .codex:
            detected = CLICredentialsDetector.detectCodexCLIAccount()
        case .claude:
            detected = CLICredentialsDetector.detectClaudeCLIAccount()
        case .supergrok:
            detected = CLICredentialsDetector.detectGrokAccounts().first
        case .cursor:
            detected = CLICredentialsDetector.detectCursorAccount()
        case .commandcode:
            detected = CLICredentialsDetector.detectCommandCodeAccount()
        case .copilot:
            detected = CLICredentialsDetector.detectCopilotAccount()
        case .opencodego:
            detected = CLICredentialsDetector.detectOpenCodeGoAccount()
        case .antigravity:
            let all = CLICredentialsDetector.detectAntigravityAccounts()
            guard !all.isEmpty else {
                showMissingCredentialsAlert(provider: provider)
                return
            }
            for var acc in all {
                if !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    acc.nickname = nickname
                }
                UnifiedAccountStore.shared.addOrUpdateAccount(acc)
                Task { _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true) }
            }
            close()
            return
        }

        guard var acc = detected else {
            showMissingCredentialsAlert(provider: provider)
            return
        }

        if !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            acc.nickname = nickname
        }
        acc.id = "\(provider.rawValue)-\(UUID().uuidString.prefix(6))"

        UnifiedAccountStore.shared.addOrUpdateAccount(acc)
        Task { _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true) }
        close()
    }

    private func connectManualAntigravity(nickname: String, accessToken: String, refreshToken: String?, email: String?) {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Access Token Required"
            alert.informativeText = "Paste a valid Antigravity Google OAuth access token."
            alert.runModal()
            return
        }

        let acc = CLICredentialsDetector.makeAntigravityAccount(
            accessToken: trimmedToken,
            refreshToken: refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email?.trimmingCharacters(in: .whitespacesAndNewlines),
            nickname: nickname
        )

        UnifiedAccountStore.shared.addOrUpdateAccount(acc)
        Task { _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true) }
        close()
    }

    private func showMissingCredentialsAlert(provider: AIProvider) {
        let alert = NSAlert()
        alert.messageText = "No Local Credentials Found"
        alert.informativeText = "Could not find local credentials for \(provider.displayName). Sign in via Antigravity or agy CLI, then try again."
        alert.runModal()
    }

    private func startGrokDeviceAuth() {
        Task { @MainActor in
            do {
                let codeRes = try await DeviceAuth.requestDeviceCode()
                if let url = codeRes.verificationUriComplete.flatMap({ URL(string: $0) }) ?? URL(string: codeRes.verificationUri) {
                    NSWorkspace.shared.open(url)
                }

                let tokenRes = try await DeviceAuth.pollForToken(deviceCode: codeRes.deviceCode, interval: codeRes.interval ?? 5)
                let auth = UnifiedAuthData.supergrok(
                    accessToken: tokenRes.accessToken,
                    refreshToken: tokenRes.refreshToken,
                    ssoToken: tokenRes.accessToken,
                    sub: nil,
                    expiresAt: Date().addingTimeInterval(Double(tokenRes.expiresIn ?? 86400))
                )

                let acc = UnifiedAccount(
                    id: "grok-\(UUID().uuidString.prefix(6))",
                    provider: .supergrok,
                    nickname: "SuperGrok Device",
                    email: nil,
                    authData: auth,
                    lastUsage: nil,
                    lastError: nil,
                    lastRefreshedAt: nil,
                    isFreePlan: false
                )

                UnifiedAccountStore.shared.addOrUpdateAccount(acc)
                _ = try? await UnifiedBillingCoordinator.shared.fetch(for: acc, force: true)
                self.close()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Device Auth Failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

// MARK: - SwiftUI Add Account Form

private struct AddAccountSwiftUIView: View {
    var onCancel: () -> Void
    var onConnectWeb: (AIProvider, String) -> Void
    var onConnectCLI: (AIProvider, String) -> Void
    var onConnectDeviceCode: () -> Void
    var onConnectManualAntigravity: (String, String, String?, String?) -> Void

    @State private var selectedProvider: AIProvider = .codex
    @State private var nickname: String = ""
    @State private var manualAccessToken: String = ""
    @State private var manualRefreshToken: String = ""
    @State private var manualEmail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.gaugeAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add AI Account")
                        .font(.headline.bold())
                    Text("Connect accounts across Codex, Claude, Grok, Cursor, Copilot, Command Code, OpenCode Go, and Antigravity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Provider Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Select Provider:")
                    .font(.subheadline.bold())

                HStack(spacing: 8) {
                    ForEach(AIProvider.allCases) { prov in
                        providerButton(prov)
                    }
                }
            }

            // Nickname
            VStack(alignment: .leading, spacing: 6) {
                Text("Account Label / Nickname:")
                    .font(.subheadline.bold())
                TextField("e.g. Work Account, Personal, Heavy Tier...", text: $nickname)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            // Connection Methods
            VStack(spacing: 8) {
                if selectedProvider.supportsWebLogin {
                    Button(action: { onConnectWeb(selectedProvider, nickname) }) {
                        HStack {
                            Image(systemName: "safari")
                            Text("Sign In with Web Browser (ChatGPT / Claude / Grok)")
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gaugeAccent.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gaugeAccent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                if selectedProvider.supportsLocalImport {
                    Button(action: { onConnectCLI(selectedProvider, nickname) }) {
                        HStack {
                            Image(systemName: "terminal")
                            Text(localImportLabel(for: selectedProvider))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                if selectedProvider.supportsManualEntry {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Manual OAuth Token:")
                            .font(.subheadline.bold())
                        TextField("Access token", text: $manualAccessToken)
                            .textFieldStyle(.roundedBorder)
                        TextField("Refresh token (optional)", text: $manualRefreshToken)
                            .textFieldStyle(.roundedBorder)
                        TextField("Google account email (optional)", text: $manualEmail)
                            .textFieldStyle(.roundedBorder)
                        Button(action: {
                            onConnectManualAntigravity(
                                nickname,
                                manualAccessToken,
                                manualRefreshToken.isEmpty ? nil : manualRefreshToken,
                                manualEmail.isEmpty ? nil : manualEmail
                            )
                        }) {
                            HStack {
                                Image(systemName: "key.fill")
                                Text("Add Antigravity Account with Token")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedProvider == .supergrok {
                    Button(action: onConnectDeviceCode) {
                        HStack {
                            Image(systemName: "qrcode")
                            Text("Use xAI Device Code Authorization")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Footer
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }

    private func providerButton(_ prov: AIProvider) -> some View {
        let isSelected = (selectedProvider == prov)
        return Button(action: { selectedProvider = prov }) {
            HStack(spacing: 5) {
                Image(systemName: prov.iconSystemName)
                    .font(.system(size: 12))
                Text(prov.shortName)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? prov.primaryAccent : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? prov.primaryAccent.opacity(0.15) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? prov.primaryAccent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func localImportLabel(for provider: AIProvider) -> String {
        switch provider {
        case .codex: return "Import from ~/.codex"
        case .claude: return "Import from ~/.claude"
        case .supergrok: return "Import from GRLD accounts"
        case .cursor: return "Import from Cursor app state"
        case .commandcode: return "Import from ~/.commandcode"
        case .copilot: return "Import via gh auth token"
        case .opencodego: return "Import from OpenCode auth.json"
        case .antigravity: return "Import all Antigravity profiles from ~/.gemini"
        }
    }
}
