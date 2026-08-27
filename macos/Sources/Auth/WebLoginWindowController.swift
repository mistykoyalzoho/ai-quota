import Cocoa
import WebKit

@MainActor
final class WebLoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private let provider: AIProvider
    private let nickname: String
    private let completion: (Result<UnifiedAccount, Error>) -> Void
    private var hasCompleted = false

    init(provider: AIProvider, nickname: String, completion: @escaping (Result<UnifiedAccount, Error>) -> Void) {
        self.provider = provider
        self.nickname = nickname.isEmpty ? "\(provider.shortName) Account" : nickname
        self.completion = completion
        super.init()
    }

    func show() {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent() // isolated session per login
        config.websiteDataStore = store

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign In — \(provider.displayName)"
        win.contentView = wv
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        let initialURL: URL
        switch provider {
        case .codex:
            initialURL = URL(string: "https://chatgpt.com/auth/login")!
        case .claude:
            initialURL = URL(string: "https://claude.ai/login")!
        case .supergrok:
            initialURL = URL(string: "https://grok.com")!
        case .cursor, .commandcode, .copilot, .opencodego, .antigravity:
            finishWithFailure(message: "\(provider.displayName) uses local import. Use 'Import from Local CLI' instead.")
            return
        }

        wv.load(URLRequest(url: initialURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasCompleted else { return }

        switch provider {
        case .codex:
            checkCodexLogin(webView)
        case .claude:
            checkClaudeLogin(webView)
        case .supergrok:
            checkGrokLogin(webView)
        case .cursor, .commandcode, .copilot, .opencodego, .antigravity:
            break
        }
    }

    private func checkCodexLogin(_ wv: WKWebView) {
        wv.callAsyncJavaScript("""
            try {
                const r = await fetch('/api/auth/session', { credentials: 'include' });
                if (!r.ok) return null;
                return await r.json();
            } catch(e) { return null; }
        """, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, !self.hasCompleted else { return }
            if case .success(let value) = result,
               let dict = value as? [String: Any],
               let accessToken = dict["accessToken"] as? String,
               !accessToken.isEmpty {

                let accountID = dict["accountId"] as? String
                let email = (dict["user"] as? [String: Any])?["email"] as? String
                let auth = UnifiedAuthData.codex(
                    accessToken: accessToken,
                    refreshToken: nil,
                    sessionToken: nil,
                    accountID: accountID,
                    expiresAt: Date().addingTimeInterval(86400)
                )

                let acc = UnifiedAccount(
                    id: "codex-\(UUID().uuidString.prefix(8))",
                    provider: .codex,
                    nickname: self.nickname,
                    email: email,
                    authData: auth,
                    lastUsage: nil,
                    lastError: nil,
                    lastRefreshedAt: nil,
                    isFreePlan: false
                )

                self.finishWithSuccess(acc)
            }
        }
    }

    private func checkClaudeLogin(_ wv: WKWebView) {
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.hasCompleted else { return }
            let sessionCookie = cookies.first { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
            if let cookie = sessionCookie, !cookie.value.isEmpty {
                // Fetch user org
                wv.callAsyncJavaScript("""
                    try {
                        const r = await fetch('/api/organizations', { credentials: 'include' });
                        if (!r.ok) return null;
                        return await r.json();
                    } catch(e) { return null; }
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                    guard let self, !self.hasCompleted else { return }
                    var orgID: String? = nil
                    var email: String? = nil

                    if case .success(let value) = result,
                       let orgs = value as? [[String: Any]],
                       let firstOrg = orgs.first {
                        orgID = firstOrg["uuid"] as? String ?? firstOrg["id"] as? String
                        email = (firstOrg["members"] as? [[String: Any]])?.first?["email"] as? String
                    }

                    let auth = UnifiedAuthData.claude(
                        accessToken: "",
                        refreshToken: nil,
                        sessionKey: cookie.value,
                        orgID: orgID ?? "",
                        rateLimitTier: "Pro",
                        expiresAt: Date().addingTimeInterval(30 * 86400)
                    )

                    let acc = UnifiedAccount(
                        id: "claude-\(UUID().uuidString.prefix(8))",
                        provider: .claude,
                        nickname: self.nickname,
                        email: email,
                        authData: auth,
                        lastUsage: nil,
                        lastError: nil,
                        lastRefreshedAt: nil,
                        isFreePlan: false
                    )

                    self.finishWithSuccess(acc)
                }
            }
        }
    }

    private func checkGrokLogin(_ wv: WKWebView) {
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.hasCompleted else { return }
            let sso = cookies.first { ($0.name == "sso" || $0.name == "sso-rw") && $0.domain.contains("grok.com") }
            if let token = sso?.value, !token.isEmpty {
                let auth = UnifiedAuthData.supergrok(
                    accessToken: token,
                    refreshToken: nil,
                    ssoToken: token,
                    sub: nil,
                    expiresAt: Date().addingTimeInterval(30 * 86400)
                )

                let acc = UnifiedAccount(
                    id: "grok-\(UUID().uuidString.prefix(8))",
                    provider: .supergrok,
                    nickname: self.nickname,
                    email: nil,
                    authData: auth,
                    lastUsage: nil,
                    lastError: nil,
                    lastRefreshedAt: nil,
                    isFreePlan: false
                )

                self.finishWithSuccess(acc)
            }
        }
    }

    private func finishWithFailure(message: String) {
        guard !hasCompleted else { return }
        hasCompleted = true
        window?.close()
        window = nil
        completion(.failure(NSError(domain: "WebLogin", code: -1, userInfo: [NSLocalizedDescriptionKey: message])))
    }

    private func finishWithSuccess(_ account: UnifiedAccount) {
        guard !hasCompleted else { return }
        hasCompleted = true
        window?.close()
        window = nil
        completion(.success(account))
    }

    func windowWillClose(_ notification: Notification) {
        if !hasCompleted {
            hasCompleted = true
            completion(.failure(NSError(domain: "WebLogin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Login window closed by user"])))
        }
    }
}
