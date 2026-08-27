import Foundation

actor CursorClient {
    static let shared = CursorClient()

    private let session: URLSession
    private let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .cursor(let accessToken, _, let membershipType) = account.authData else {
            throw NSError(domain: "CursorClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Cursor credentials"])
        }

        guard !accessToken.isEmpty else {
            throw NSError(domain: "CursorClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "No Cursor access token. Open Cursor and sign in, then re-import."])
        }

        var effectiveToken = accessToken
        if let fresh = CLICredentialsDetector.detectCursorAccount(),
           case .cursor(let freshToken, _, let freshMembership) = fresh.authData,
           !freshToken.isEmpty {
            effectiveToken = freshToken
            if freshToken != accessToken {
                var updated = account
                updated.authData = .cursor(accessToken: freshToken, email: account.email, membershipType: freshMembership)
                UnifiedAccountStore.shared.addOrUpdateAccount(updated)
            }
        }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CursorClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CursorClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Cursor HTTP \(http.statusCode). Token may be expired — re-import from Cursor."])
        }

        return try parseUsageResponse(data, membershipType: membershipType)
    }

    private func parseUsageResponse(_ data: Data, membershipType: String?) throws -> UnifiedQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(CursorUsageResponse.self, from: data)

        let plan = raw.planUsage
        let totalPercent = Int((plan?.totalPercentUsed ?? 0).rounded())
        let apiPercent = Int((plan?.apiPercentUsed ?? 0).rounded())
        let limitCents = plan?.limit ?? 0
        let includedSpendCents = plan?.includedSpend ?? plan?.totalSpend ?? 0

        let billingEnd = raw.billingCycleEnd.flatMap { parseEpochMillis($0) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let auto = plan?.autoPercentUsed {
            breakdowns.append(UnifiedBreakdownItem(name: "Auto Mode", usagePercent: Int(auto.rounded()), details: nil))
        }
        if apiPercent > 0 {
            breakdowns.append(UnifiedBreakdownItem(name: "API / Named Models", usagePercent: apiPercent, details: nil))
        }
        if let limit = plan?.limit, limit > 0 {
            let spentUSD = Double(includedSpendCents) / 100.0
            let limitUSD = Double(limit) / 100.0
            breakdowns.append(UnifiedBreakdownItem(name: "Included Spend", usagePercent: totalPercent, details: String(format: "$%.2f / $%.2f", spentUSD, limitUSD)))
        }

        let tier = membershipType?.capitalized ?? "Cursor Pro"

        return UnifiedQuotaSnapshot(
            primaryPercent: totalPercent,
            primaryLabel: "Plan",
            primaryResetsAt: billingEnd,
            primaryLimitReached: totalPercent >= 100 || (plan?.remaining ?? 1) <= 0,
            secondaryPercent: apiPercent > 0 ? apiPercent : nil,
            secondaryLabel: apiPercent > 0 ? "API" : nil,
            secondaryResetsAt: billingEnd,
            secondaryLimitReached: apiPercent >= 100,
            planTier: tier,
            extraUsageSpent: limitCents > 0 ? Double(includedSpendCents) / 100.0 : nil,
            extraUsageLimit: limitCents > 0 ? Double(limitCents) / 100.0 : nil,
            currency: "$",
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private func parseEpochMillis(_ value: String) -> Date? {
        if let ms = Double(value) {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return DateParsingHelper.parseISO8601(value)
    }

    private struct CursorUsageResponse: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let planUsage: PlanUsage?

        struct PlanUsage: Decodable {
            let totalSpend: Int?
            let includedSpend: Int?
            let remaining: Int?
            let limit: Int?
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
            let totalPercentUsed: Double?
        }
    }
}
