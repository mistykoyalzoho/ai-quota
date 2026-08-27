import Foundation
import WebKit

actor ClaudeClient {
    static let shared = ClaudeClient()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .claude(var accessToken, _, var sessionKey, var orgID, let rateLimitTier, _) = account.authData else {
            throw NSError(domain: "ClaudeClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Claude credentials"])
        }

        // Try OAuth first
        if !accessToken.isEmpty {
            do {
                return try await fetchOAuthUsage(accessToken: accessToken, rateLimitTier: rateLimitTier)
            } catch {
                // Try reloading freshest credentials from CLI / Keychain
                if let fresh = CLICredentialsDetector.detectClaudeCLIAccount(),
                   case .claude(let freshToken, _, _, _, _, _) = fresh.authData,
                   !freshToken.isEmpty && freshToken != accessToken {
                    accessToken = freshToken
                    var updated = account
                    updated.authData = fresh.authData
                    UnifiedAccountStore.shared.addOrUpdateAccount(updated)
                    do {
                        return try await fetchOAuthUsage(accessToken: freshToken, rateLimitTier: rateLimitTier)
                    } catch {}
                }

                // If web session is available, try Web session
                if let key = sessionKey, let org = orgID, !key.isEmpty, !org.isEmpty {
                    return try await fetchWebUsage(sessionKey: key, orgID: org)
                }

                // Try probing WebKit cookies for live session
                if let (wkKey, wkOrg) = await probeWebKitSession() {
                    sessionKey = wkKey
                    orgID = wkOrg
                    let newAuth = UnifiedAuthData.claude(
                        accessToken: accessToken,
                        refreshToken: nil,
                        sessionKey: wkKey,
                        orgID: wkOrg,
                        rateLimitTier: rateLimitTier,
                        expiresAt: Date().addingTimeInterval(30 * 86400)
                    )
                    var updated = account
                    updated.authData = newAuth
                    UnifiedAccountStore.shared.addOrUpdateAccount(updated)
                    return try await fetchWebUsage(sessionKey: wkKey, orgID: wkOrg)
                }

                throw NSError(
                    domain: "ClaudeClient",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Claude session expired. Sign in via Browser or run `claude` in terminal."]
                )
            }
        }

        if let key = sessionKey, let org = orgID, !key.isEmpty, !org.isEmpty {
            return try await fetchWebUsage(sessionKey: key, orgID: org)
        }

        if let (wkKey, wkOrg) = await probeWebKitSession() {
            return try await fetchWebUsage(sessionKey: wkKey, orgID: wkOrg)
        }

        throw NSError(
            domain: "ClaudeClient",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Claude session expired. Click '+' to Sign In via Browser."]
        )
    }

    private func fetchOAuthUsage(accessToken: String, rateLimitTier: String?) async throws -> UnifiedQuotaSnapshot {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ClaudeClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude OAuth HTTP \(http.statusCode)"])
        }

        return try parseClaudeResponse(data, defaultTier: rateLimitTier ?? "Claude Pro")
    }

    private func fetchWebUsage(sessionKey: String, orgID: String) async throws -> UnifiedQuotaSnapshot {
        var req = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(orgID)/usage")!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ClaudeClient", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Claude Web HTTP error"])
        }

        return try parseClaudeResponse(data, defaultTier: "Claude Web")
    }

    private func parseClaudeResponse(_ data: Data, defaultTier: String) throws -> UnifiedQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(RawClaudeUsageResponse.self, from: data)

        let fiveHourVal = Int((raw.fiveHour?.utilization ?? 0).rounded())
        let sevenDayBucket = raw.preferredSevenDay
        let sevenDayVal = Int((sevenDayBucket?.utilization ?? 0).rounded())

        let fiveHourReset = raw.fiveHour?.resetsAt.flatMap { DateParsingHelper.parseISO8601($0) }
        let sevenDayReset = sevenDayBucket?.resetsAt.flatMap { DateParsingHelper.parseISO8601($0) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let fh = raw.fiveHour {
            breakdowns.append(UnifiedBreakdownItem(name: "5h Window", usagePercent: Int((fh.utilization ?? 0).rounded()), details: fh.resetsAt))
        }
        if let sd = sevenDayBucket {
            breakdowns.append(UnifiedBreakdownItem(name: "7d Window", usagePercent: Int((sd.utilization ?? 0).rounded()), details: sd.resetsAt))
        }

        let extraSpent = raw.extraUsage?.usedCredits
        let extraLimit = raw.extraUsage?.monthlyLimit

        return UnifiedQuotaSnapshot(
            primaryPercent: fiveHourVal,
            primaryLabel: "5h",
            primaryResetsAt: fiveHourReset,
            primaryLimitReached: fiveHourVal >= 100,
            secondaryPercent: sevenDayVal,
            secondaryLabel: "7d",
            secondaryResetsAt: sevenDayReset,
            secondaryLimitReached: sevenDayVal >= 100,
            planTier: defaultTier,
            extraUsageSpent: extraSpent,
            extraUsageLimit: extraLimit,
            currency: raw.extraUsage?.currency ?? "$",
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private func probeWebKitSession() async -> (sessionKey: String, orgID: String)? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    let sessionCookie = cookies.first { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
                    guard let key = sessionCookie?.value, !key.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Try retrieving cached orgID
                    let orgCookie = cookies.first { $0.name.contains("org") && $0.domain.contains("claude.ai") }?.value ?? ""
                    continuation.resume(returning: (key, orgCookie))
                }
            }
        }
    }

    private struct RawClaudeUsageResponse: Decodable {
        let fiveHour: WindowBucket?
        let sevenDay: WindowBucket?
        let sevenDayOauthApps: WindowBucket?
        let sevenDaySonnet: WindowBucket?
        let extraUsage: ExtraUsageBucket?

        var preferredSevenDay: WindowBucket? {
            sevenDay ?? sevenDayOauthApps ?? sevenDaySonnet
        }

        struct WindowBucket: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }

        struct ExtraUsageBucket: Decodable {
            let isEnabled: Bool?
            let monthlyLimit: Double?
            let usedCredits: Double?
            let currency: String?
        }
    }
}
