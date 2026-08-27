import Foundation

actor SuperGrokClient {
    static let shared = SuperGrokClient()
    private let session: URLSession

    private static let clientId = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .supergrok(let accessToken, let refreshToken, let ssoToken, let sub, let expiresAt) = account.authData else {
            throw NSError(domain: "SuperGrokClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid SuperGrok credentials"])
        }

        var effectiveToken = accessToken
        var currentAuth = account.authData

        // Check if token is expired and refreshToken is available
        if let exp = expiresAt, exp <= Date().addingTimeInterval(-60), let rt = refreshToken, !rt.isEmpty {
            if let refreshed = try? await refreshOAuthToken(refreshToken: rt) {
                effectiveToken = refreshed.accessToken
                currentAuth = .supergrok(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken ?? rt,
                    ssoToken: ssoToken,
                    sub: sub,
                    expiresAt: Date().addingTimeInterval(Double(refreshed.expiresIn ?? 86400))
                )
                var updatedAcc = account
                updatedAcc.authData = currentAuth
                UnifiedAccountStore.shared.addOrUpdateAccount(updatedAcc)
            }
        }

        var req = URLRequest(url: Self.billingURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        if let sub, !sub.isEmpty {
            req.setValue(sub, forHTTPHeaderField: "x-userid")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("grld-macos-oauth", forHTTPHeaderField: "x-grok-client-version")
        req.setValue("GRLD-macOS/oauth", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SuperGrokClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            // Attempt one refresh on 401
            if let rt = refreshToken, !rt.isEmpty,
               let refreshed = try? await refreshOAuthToken(refreshToken: rt) {
                effectiveToken = refreshed.accessToken
                let newAuth = UnifiedAuthData.supergrok(
                    accessToken: refreshed.accessToken,
                    refreshToken: refreshed.refreshToken ?? rt,
                    ssoToken: ssoToken,
                    sub: sub,
                    expiresAt: Date().addingTimeInterval(Double(refreshed.expiresIn ?? 86400))
                )
                var updatedAcc = account
                updatedAcc.authData = newAuth
                UnifiedAccountStore.shared.addOrUpdateAccount(updatedAcc)

                var retryReq = URLRequest(url: Self.billingURL)
                retryReq.httpMethod = "GET"
                retryReq.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                retryReq.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
                if let sub, !sub.isEmpty { retryReq.setValue(sub, forHTTPHeaderField: "x-userid") }
                retryReq.setValue("application/json", forHTTPHeaderField: "Accept")

                let (retryData, retryResp) = try await session.data(for: retryReq)
                if let retryHttp = retryResp as? HTTPURLResponse, (200...299).contains(retryHttp.statusCode) {
                    return try parseBillingJSON(retryData, isFreePlan: account.isFreePlan)
                }
            }
            throw NSError(domain: "SuperGrokClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "SuperGrok session expired"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "SuperGrokClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Grok HTTP \(http.statusCode)"])
        }

        return try parseBillingJSON(data, isFreePlan: account.isFreePlan)
    }

    private func refreshOAuthToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(Self.clientId)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "SuperGrokClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Refresh failed"])
        }

        struct TokenRes: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let res = try JSONDecoder().decode(TokenRes.self, from: data)
        return (res.access_token, res.refresh_token, res.expires_in)
    }

    private func parseBillingJSON(_ data: Data, isFreePlan: Bool) throws -> UnifiedQuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cfg = root["config"] as? [String: Any]
        else {
            throw NSError(domain: "SuperGrokClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Grok JSON"])
        }

        let usedF: Double? = {
            if let n = cfg["creditUsagePercent"] as? NSNumber { return n.doubleValue }
            if let d = cfg["creditUsagePercent"] as? Double { return d }
            return nil
        }()
        let used = usedF.map { min(100, max(0, Int($0.rounded()))) }

        var periodLabel = "7d"
        var periodStart: String?
        var periodEnd: String?
        if let period = cfg["currentPeriod"] as? [String: Any] {
            let t = period["type"] as? String ?? ""
            if t.uppercased().contains("MONTHLY") { periodLabel = "30d" }
            periodStart = period["start"] as? String
            periodEnd = period["end"] as? String
        }
        if periodStart == nil { periodStart = cfg["billingPeriodStart"] as? String }
        if periodEnd == nil { periodEnd = cfg["billingPeriodEnd"] as? String }

        var products: [UnifiedBreakdownItem] = []
        if let arr = cfg["productUsage"] as? [[String: Any]] {
            for p in arr {
                let nameRaw = p["product"] as? String ?? "Unknown"
                guard let n = p["usagePercent"] as? NSNumber else { continue }
                let pct = min(100, max(0, Int(n.doubleValue.rounded())))
                guard pct > 0 else { continue }
                products.append(UnifiedBreakdownItem(name: nameRaw, usagePercent: pct, details: nil))
            }
        }

        let usedFinal = used ?? products.map(\.usagePercent).max() ?? 0
        let tier = (root["subscriptionTier"] as? String)
            ?? (root["subscription_tier"] as? String)
            ?? (isFreePlan ? "Free Plan" : "SuperGrok")

        let resetDate = calculateResetDate(periodStart: periodStart, periodEnd: periodEnd)

        let topProduct = products.first
        let topPercent = topProduct?.usagePercent

        return UnifiedQuotaSnapshot(
            primaryPercent: usedFinal,
            primaryLabel: periodLabel,
            primaryResetsAt: resetDate,
            primaryLimitReached: usedFinal >= 100,
            secondaryPercent: topPercent,
            secondaryLabel: topProduct != nil ? shortProduct(topProduct!.name) : "Build",
            secondaryResetsAt: resetDate,
            secondaryLimitReached: (topPercent ?? 0) >= 100,
            planTier: tier,
            extraUsageSpent: nil,
            extraUsageLimit: nil,
            currency: "$",
            breakdownItems: products.sorted { $0.usagePercent > $1.usagePercent },
            fetchedAt: Date()
        )
    }

    private func calculateResetDate(periodStart: String?, periodEnd: String?) -> Date? {
        if let endStr = periodEnd, let d = DateParsingHelper.parseISO8601(endStr) {
            if d > Date() { return d }
        }

        if let startStr = periodStart, let start = DateParsingHelper.parseISO8601(startStr) {
            let periodSecs: TimeInterval = 7 * 86_400
            var projected = start.addingTimeInterval(periodSecs)
            while projected <= Date() {
                projected = projected.addingTimeInterval(periodSecs)
            }
            return projected
        }

        let cal = Calendar.autoupdatingCurrent
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 59; comps.second = 59
        return cal.date(from: comps)
    }

    private func shortProduct(_ name: String) -> String {
        switch name.lowercased() {
        case "grok build", "build": return "Build"
        case "chat": return "Chat"
        case "imagine": return "Imagine"
        case "voice": return "Voice"
        case "api": return "API"
        default: return name.prefix(6).capitalized
        }
    }
}
