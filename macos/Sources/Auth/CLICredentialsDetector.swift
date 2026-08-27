import Foundation
import Security
import LocalAuthentication

enum CLICredentialsDetector {

    // MARK: - Detect All CLI Accounts

    static func detectAllAccounts() -> [UnifiedAccount] {
        var detected: [UnifiedAccount] = []

        if let codex = detectCodexCLIAccount() {
            detected.append(codex)
        }

        if let claude = detectClaudeCLIAccount() {
            detected.append(claude)
        }

        detected.append(contentsOf: detectGrokAccounts())

        if let cursor = detectCursorAccount() {
            detected.append(cursor)
        }

        if let commandCode = detectCommandCodeAccount() {
            detected.append(commandCode)
        }

        if let copilot = detectCopilotAccount() {
            detected.append(copilot)
        }

        if let opencodeGo = detectOpenCodeGoAccount() {
            detected.append(opencodeGo)
        }

        detected.append(contentsOf: detectAntigravityAccounts())

        return detected
    }

    // MARK: - 1. OpenAI Codex CLI (~/.codex/auth.json)

    static func detectCodexCLIAccount() -> UnifiedAccount? {
        let env = ProcessInfo.processInfo.environment
        let codexHome = env["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let authURL = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let tokens = json["tokens"] as? [String: Any]
        let accessToken = (tokens?["access_token"] as? String ?? tokens?["accessToken"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let refreshToken = tokens?["refresh_token"] as? String ?? tokens?["refreshToken"] as? String
        let idToken = tokens?["id_token"] as? String ?? tokens?["idToken"] as? String
        let accountID = tokens?["account_id"] as? String
            ?? tokens?["accountId"] as? String
            ?? json["account_id"] as? String
            ?? jwtAccountID(idToken)
            ?? jwtAccountID(accessToken)

        let email = jwtEmail(idToken) ?? jwtEmail(accessToken)
        let expiresAt = jwtExpiry(accessToken)

        let auth = UnifiedAuthData.codex(
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionToken: nil,
            accountID: accountID,
            expiresAt: expiresAt
        )

        return UnifiedAccount(
            id: "codex-cli-primary",
            provider: .codex,
            nickname: "Codex CLI",
            email: email,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 2. Claude Code CLI (~/.claude/.credentials.json & Keychain)

    static func detectClaudeCLIAccount() -> UnifiedAccount? {
        let env = ProcessInfo.processInfo.environment
        let configDir = env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        let credsURL = URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")

        var oauthData: [String: Any]?

        if FileManager.default.fileExists(atPath: credsURL.path),
           let data = try? Data(contentsOf: credsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any] {
            oauthData = oauth
        }

        if oauthData == nil {
            // Try Keychain
            if let kcData = readClaudeKeychainData(),
               let json = try? JSONSerialization.jsonObject(with: kcData) as? [String: Any],
               let oauth = json["claudeAiOauth"] as? [String: Any] {
                oauthData = oauth
            }
        }

        guard let oauth = oauthData else { return nil }
        let accessToken = (oauth["accessToken"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let refreshToken = oauth["refreshToken"] as? String
        let rateLimitTier = oauth["rateLimitTier"] as? String
        let expiresEpoch = oauth["expiresAt"] as? Double
        let expiresAt = expiresEpoch.map { Date(timeIntervalSince1970: $0 / 1000.0) }

        let auth = UnifiedAuthData.claude(
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionKey: nil,
            orgID: nil,
            rateLimitTier: rateLimitTier,
            expiresAt: expiresAt
        )

        return UnifiedAccount(
            id: "claude-cli-primary",
            provider: .claude,
            nickname: "Claude Code CLI",
            email: nil,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 3. SuperGrok Accounts (GRLD / OIDC)

    static func detectGrokAccounts() -> [UnifiedAccount] {
        var accounts: [UnifiedAccount] = []
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let grldURL = appSupport.appendingPathComponent("GRLD/accounts.json")

        if FileManager.default.fileExists(atPath: grldURL.path),
           let data = try? Data(contentsOf: grldURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawList = json["accounts"] as? [[String: Any]] {

            for item in rawList {
                guard let id = item["id"] as? String else { continue }
                let tokens = item["tokens"] as? [String: Any]
                let sessionToken = (tokens?["accessToken"] as? String ?? item["sessionToken"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sessionToken.isEmpty else { continue }

                let label = item["label"] as? String ?? "SuperGrok"
                let refreshToken = tokens?["refreshToken"] as? String ?? item["refreshToken"] as? String
                let expiresEpoch = tokens?["expiresAt"] as? Double
                let expiresAt = expiresEpoch.map { Date(timeIntervalSince1970: $0) } ?? DateParsingHelper.parseISO8601(item["expiresAt"] as? String)
                let sub = tokens?["userId"] as? String ?? item["sub"] as? String
                let isFreePlan = item["isFreePlan"] as? Bool ?? false

                let auth = UnifiedAuthData.supergrok(
                    accessToken: sessionToken,
                    refreshToken: refreshToken,
                    ssoToken: sessionToken,
                    sub: sub,
                    expiresAt: expiresAt
                )

                let acc = UnifiedAccount(
                    id: "grok-\(id)",
                    provider: .supergrok,
                    nickname: label,
                    email: (item["email"] as? String) ?? (label.contains("@") ? label : nil),
                    authData: auth,
                    lastUsage: nil,
                    lastError: nil,
                    lastRefreshedAt: nil,
                    isFreePlan: isFreePlan
                )
                accounts.append(acc)
            }
        }

        return accounts
    }

    // MARK: - 4. Cursor IDE (state.vscdb)

    static func detectCursorAccount() -> UnifiedAccount? {
        let home = NSHomeDirectory()
        let dbPath = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let token = LocalSQLiteReader.stringValue(
            dbPath: dbPath,
            query: "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"
        )
        guard let token, !token.isEmpty else { return nil }

        let email = LocalSQLiteReader.stringValue(
            dbPath: dbPath,
            query: "SELECT value FROM ItemTable WHERE key='cursorAuth/cachedEmail';"
        )
        let membership = LocalSQLiteReader.stringValue(
            dbPath: dbPath,
            query: "SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType';"
        )

        let auth = UnifiedAuthData.cursor(
            accessToken: token,
            email: email,
            membershipType: membership
        )

        return UnifiedAccount(
            id: "cursor-primary",
            provider: .cursor,
            nickname: "Cursor",
            email: email,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 5. Command Code CLI (~/.commandcode/auth.json)

    static func detectCommandCodeAccount() -> UnifiedAccount? {
        let authURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".commandcode/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = (json["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }

        let userId = json["userId"] as? String
        let userName = json["userName"] as? String

        let auth = UnifiedAuthData.commandcode(
            apiKey: apiKey,
            userId: userId,
            userName: userName
        )

        return UnifiedAccount(
            id: "commandcode-primary",
            provider: .commandcode,
            nickname: "Command Code",
            email: userName,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 6. GitHub Copilot (gh CLI token)

    static func detectCopilotAccount() -> UnifiedAccount? {
        guard let token = readGitHubCLIToken(), !token.isEmpty else { return nil }

        let login = readCopilotConfigLogin()

        let auth = UnifiedAuthData.copilot(
            accessToken: token,
            login: login
        )

        return UnifiedAccount(
            id: "copilot-primary",
            provider: .copilot,
            nickname: "GitHub Copilot",
            email: login,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 7. OpenCode Go (~/.local/share/opencode/auth.json)

    static func detectOpenCodeGoAccount() -> UnifiedAccount? {
        let authURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/opencode/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var apiKey: String?
        if let go = json["opencode-go"] as? [String: Any] {
            apiKey = go["key"] as? String
        }
        if apiKey == nil, let opencode = json["opencode"] as? [String: Any] {
            apiKey = opencode["key"] as? String
        }

        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }

        let auth = UnifiedAuthData.opencodego(
            apiKey: key,
            accountDescription: "OpenCode Go"
        )

        return UnifiedAccount(
            id: "opencodego-primary",
            provider: .opencodego,
            nickname: "OpenCode Go",
            email: nil,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    // MARK: - 8. Antigravity (Google Antigravity IDE / agy CLI)

    struct AntigravityOAuthCredentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let email: String?
        let authMethod: String?
        let tokenSourcePath: String?
        let projectId: String?
        let expiresAt: Date?
    }

    static func detectAntigravityAccounts() -> [UnifiedAccount] {
        var accounts: [UnifiedAccount] = []
        var seenFingerprints = Set<String>()

        for (path, label) in discoverAntigravityTokenPaths() {
            guard let creds = readAntigravityOAuthFile(at: path) else { continue }
            let fingerprint = tokenFingerprint(creds.accessToken)
            guard !fingerprint.isEmpty, !seenFingerprints.contains(fingerprint) else { continue }
            seenFingerprints.insert(fingerprint)

            let email = creds.email ?? resolveAntigravityEmail(forTokenPath: path)
            let accountId = antigravityAccountId(email: email, fingerprint: fingerprint)

            let auth = UnifiedAuthData.antigravity(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken,
                email: email,
                authMethod: creds.authMethod,
                tokenSourcePath: path,
                projectId: creds.projectId
            )

            let nickname: String
            if let email, !email.isEmpty {
                nickname = label.isEmpty ? email : "\(label) (\(email))"
            } else {
                nickname = label.isEmpty ? "Antigravity" : label
            }

            accounts.append(UnifiedAccount(
                id: accountId,
                provider: .antigravity,
                nickname: nickname,
                email: email,
                authData: auth,
                lastUsage: nil,
                lastError: nil,
                lastRefreshedAt: nil,
                isFreePlan: false
            ))
        }

        return accounts
    }

    static func refreshAntigravityCredentials(
        email: String?,
        tokenSourcePath: String?,
        currentAccessToken: String
    ) -> AntigravityOAuthCredentials? {
        var candidatePaths: [String] = []
        if let tokenSourcePath, !tokenSourcePath.isEmpty {
            candidatePaths.append(tokenSourcePath)
        }
        candidatePaths.append(contentsOf: discoverAntigravityTokenPaths().map(\.path))

        let currentFingerprint = tokenFingerprint(currentAccessToken)

        for path in candidatePaths {
            guard let creds = readAntigravityOAuthFile(at: path) else { continue }

            if let email, !email.isEmpty {
                let resolvedEmail = creds.email ?? resolveAntigravityEmail(forTokenPath: path)
                if let resolvedEmail, resolvedEmail.caseInsensitiveCompare(email) != .orderedSame {
                    continue
                }
            } else if !currentFingerprint.isEmpty {
                let fingerprint = tokenFingerprint(creds.accessToken)
                if fingerprint != currentFingerprint {
                    continue
                }
            }

            if creds.accessToken != currentAccessToken || creds.refreshToken != nil {
                return creds
            }
            return creds.accessToken.isEmpty ? nil : creds
        }

        return nil
    }

    static func makeAntigravityAccount(
        accessToken: String,
        refreshToken: String?,
        email: String?,
        nickname: String
    ) -> UnifiedAccount {
        let fingerprint = tokenFingerprint(accessToken)
        let accountId = antigravityAccountId(email: email, fingerprint: fingerprint)
        let auth = UnifiedAuthData.antigravity(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            authMethod: "manual",
            tokenSourcePath: nil,
            projectId: nil
        )

        return UnifiedAccount(
            id: accountId,
            provider: .antigravity,
            nickname: nickname.isEmpty ? (email ?? "Antigravity") : nickname,
            email: email,
            authData: auth,
            lastUsage: nil,
            lastError: nil,
            lastRefreshedAt: nil,
            isFreePlan: false
        )
    }

    private static func discoverAntigravityTokenPaths() -> [(path: String, label: String)] {
        let home = NSHomeDirectory()
        var paths: [(String, String)] = [
            ("\(home)/.gemini/antigravity-cli/antigravity-oauth-token", "agy CLI"),
            ("\(home)/.gemini/jetski-standalone-oauth-token", "Antigravity IDE"),
        ]

        let extraRoots = [
            "\(home)/.gemini",
            "\(home)/Library/Application Support/Antigravity",
            "\(home)/Library/Application Support/Antigravity IDE",
        ]

        let tokenNames = [
            "antigravity-oauth-token",
            "jetski-standalone-oauth-token",
            "oauth-token",
        ]

        for root in extraRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard tokenNames.contains(name) else { continue }
                let path = fileURL.path
                if paths.contains(where: { $0.0 == path }) { continue }
                let label = name == "jetski-standalone-oauth-token" ? "Antigravity IDE" : "Antigravity"
                paths.append((path, label))
            }
        }

        return paths
    }

    private static func readAntigravityOAuthFile(at path: String) -> AntigravityOAuthCredentials? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tokenObject = (json["token"] as? [String: Any]) ?? json
        let accessToken = (tokenObject["access_token"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let refreshToken = tokenObject["refresh_token"] as? String
        let authMethod = json["auth_method"] as? String
        let email = json["email"] as? String
        let projectId = json["project_id"] as? String ?? json["projectId"] as? String
        let expiresAt = parseAntigravityExpiry(tokenObject["expiry"] as? String)

        return AntigravityOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            authMethod: authMethod,
            tokenSourcePath: path,
            projectId: projectId,
            expiresAt: expiresAt
        )
    }

    private static func resolveAntigravityEmail(forTokenPath path: String) -> String? {
        let home = NSHomeDirectory()
        let vaultURL = URL(fileURLWithPath: "\(home)/.gemini/gui/accounts_vault.json")
        if let data = try? Data(contentsOf: vaultURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accounts = json["accounts"] as? [[String: Any]] {
            if accounts.count == 1, let email = accounts[0]["email"] as? String {
                return email
            }
            if path.contains("antigravity-cli"), let active = json["activeAccountId"] as? String {
                if let match = accounts.first(where: { ($0["id"] as? String) == active }) {
                    return match["email"] as? String
                }
            }
        }

        let googleAccountsURL = URL(fileURLWithPath: "\(home)/.gemini/google_accounts.json")
        if let data = try? Data(contentsOf: googleAccountsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String, !active.isEmpty {
            return active
        }

        return nil
    }

    private static func antigravityAccountId(email: String?, fingerprint: String) -> String {
        if let email, !email.isEmpty {
            let slug = email
                .lowercased()
                .replacingOccurrences(of: "@", with: "_at_")
                .replacingOccurrences(of: ".", with: "_")
            return "antigravity-\(slug)"
        }
        return "antigravity-\(fingerprint.prefix(12))"
    }

    private static func tokenFingerprint(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return trimmed }
        return String(trimmed.prefix(16))
    }

    private static func parseAntigravityExpiry(_ value: String?) -> Date? {
        guard let value else { return nil }
        return DateParsingHelper.parseISO8601(value)
    }

    // MARK: - Helpers

    private static func readClaudeKeychainData() -> Data? {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationContext: authContext
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func jwtAccountID(_ token: String?) -> String? {
        guard let json = jwtPayload(token) else { return nil }
        if let aid = json["chatgpt_account_id"] as? String { return aid }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String ?? auth["account_id"] as? String
        }
        return nil
    }

    private static func jwtEmail(_ token: String?) -> String? {
        guard let json = jwtPayload(token) else { return nil }
        if let email = json["email"] as? String, !email.isEmpty { return email }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let email = auth["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    private static func jwtExpiry(_ token: String?) -> Date? {
        guard let json = jwtPayload(token),
              let exp = json["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func readGitHubCLIToken() -> String? {
        let ghPaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(NSHomeDirectory())/.npm-global/bin/gh"
        ]
        let gh = ghPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ghPath = gh else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil
        } catch {
            return nil
        }
    }

    private static func readCopilotConfigLogin() -> String? {
        let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".copilot/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastUser = json["lastLoggedInUser"] as? [String: Any]
        else { return nil }
        return lastUser["login"] as? String
    }
}
