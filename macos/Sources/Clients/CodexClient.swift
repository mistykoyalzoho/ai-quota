import Foundation

actor CodexClient {
    static let shared = CodexClient()
    private let session: URLSession
    private let baseURL = URL(string: "https://chatgpt.com")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .codex(let accessToken, _, let sessionToken, let accountID, _) = account.authData else {
            throw NSError(domain: "CodexClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Codex credentials"])
        }

        var effectiveToken = accessToken
        if let st = sessionToken, !st.isEmpty {
            if let refreshed = try? await refreshWithSessionToken(st) {
                effectiveToken = refreshed
            }
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("/backend-api/wham/usage"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CodexClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network connection"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CodexClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Codex HTTP \(http.statusCode)"])
        }

        return try parseWhamUsage(data)
    }

    private func parseWhamUsage(_ data: Data) throws -> UnifiedQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(WhamUsageResponse.self, from: data)

        let rateLimit = raw.rateLimit
        let primary = rateLimit?.primaryWindow
        let secondary = rateLimit?.secondaryWindow

        // When secondary is nil and primary is weekly (limitWindowSeconds >= 6 days)
        let primaryIsWeekly = secondary == nil && (primary?.limitWindowSeconds ?? 0) >= 6 * 86_400
        let weekly = secondary ?? (primaryIsWeekly ? primary : nil)
        let hourly = primaryIsWeekly ? nil : primary

        let weeklyUsed = weekly?.usedPercent ?? 0
        let weeklyReset = weekly?.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let hourlyUsed = hourly?.usedPercent ?? 0
        let hourlyReset = hourly?.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let h = hourly {
            breakdowns.append(UnifiedBreakdownItem(name: "5h Window", usagePercent: h.usedPercent ?? 0, details: h.resetAfterSeconds.map { "\($0 / 60)m remaining" }))
        }
        if let w = weekly {
            breakdowns.append(UnifiedBreakdownItem(name: "7d Window", usagePercent: w.usedPercent ?? 0, details: w.resetAfterSeconds.map { "\($0 / 3600)h remaining" }))
        }

        let tier = raw.planType?.capitalized ?? "Team"

        if primaryIsWeekly {
            // Account only has weekly quota
            return UnifiedQuotaSnapshot(
                primaryPercent: weeklyUsed,
                primaryLabel: "7d",
                primaryResetsAt: weeklyReset,
                primaryLimitReached: weeklyUsed >= 100 || (rateLimit?.limitReached ?? false),
                secondaryPercent: nil,
                secondaryLabel: nil,
                secondaryResetsAt: nil,
                secondaryLimitReached: false,
                planTier: tier,
                extraUsageSpent: nil,
                extraUsageLimit: nil,
                currency: "$",
                breakdownItems: breakdowns,
                fetchedAt: Date()
            )
        } else {
            // Account has both hourly and weekly quotas
            return UnifiedQuotaSnapshot(
                primaryPercent: hourlyUsed,
                primaryLabel: formatWindowDuration(hourly?.limitWindowSeconds ?? 18000),
                primaryResetsAt: hourlyReset,
                primaryLimitReached: hourlyUsed >= 100,
                secondaryPercent: weeklyUsed,
                secondaryLabel: "7d",
                secondaryResetsAt: weeklyReset,
                secondaryLimitReached: weeklyUsed >= 100 || (rateLimit?.limitReached ?? false),
                planTier: tier,
                extraUsageSpent: nil,
                extraUsageLimit: nil,
                currency: "$",
                breakdownItems: breakdowns,
                fetchedAt: Date()
            )
        }
    }

    private func formatWindowDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        if hours > 0 { return "\(hours)h" }
        let mins = seconds / 60
        return "\(mins)m"
    }

    private func refreshWithSessionToken(_ sessionToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/api/auth/session")!)
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("__Secure-next-auth.session-token=\(sessionToken)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw NSError(domain: "CodexClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Session refresh failed"])
        }

        struct SessionResponse: Decodable { let accessToken: String }
        let res = try JSONDecoder().decode(SessionResponse.self, from: data)
        return res.accessToken
    }

    // MARK: - API Decodable Types

    private struct WhamUsageResponse: Decodable {
        let userId: String?
        let accountId: String?
        let email: String?
        let planType: String?
        let rateLimit: RateLimitInfo?

        struct RateLimitInfo: Decodable {
            let allowed: Bool?
            let limitReached: Bool?
            let primaryWindow: WindowBucket?
            let secondaryWindow: WindowBucket?

            struct WindowBucket: Decodable {
                let usedPercent: Int?
                let limitWindowSeconds: Int?
                let resetAfterSeconds: Int?
                let resetAt: Int?
            }
        }
    }
}
