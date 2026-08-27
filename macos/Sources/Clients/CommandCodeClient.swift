import Foundation

actor CommandCodeClient {
    static let shared = CommandCodeClient()

    private let session: URLSession
    private let creditsURL = URL(string: "https://api.commandcode.ai/alpha/billing/credits")!
    private let summaryURL = URL(string: "https://api.commandcode.ai/alpha/usage/summary")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .commandcode(let apiKey, _, let userName) = account.authData else {
            throw NSError(domain: "CommandCodeClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Command Code credentials"])
        }

        guard !apiKey.isEmpty else {
            throw NSError(domain: "CommandCodeClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "No Command Code API key. Run `commandcode` and sign in, or add ~/.commandcode/auth.json."])
        }

        var creditsReq = URLRequest(url: creditsURL)
        creditsReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        creditsReq.setValue("application/json", forHTTPHeaderField: "Accept")

        var summaryReq = URLRequest(url: summaryURL)
        summaryReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        summaryReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (creditsData, creditsResp) = try await session.data(for: creditsReq)
        guard let http = creditsResp as? HTTPURLResponse else {
            throw NSError(domain: "CommandCodeClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CommandCodeClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Command Code HTTP \(http.statusCode). API key may be invalid."])
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let credits = try decoder.decode(CreditsResponse.self, from: creditsData)

        var summary: SummaryResponse?
        if let (summaryData, summaryResp) = try? await session.data(for: summaryReq),
           let summaryHttp = summaryResp as? HTTPURLResponse,
           (200...299).contains(summaryHttp.statusCode) {
            summary = try? decoder.decode(SummaryResponse.self, from: summaryData)
        }

        return buildSnapshot(credits: credits, summary: summary, userName: userName)
    }

    private func buildSnapshot(credits: CreditsResponse, summary: SummaryResponse?, userName: String?) -> UnifiedQuotaSnapshot {
        let fiveHour = credits.windowLimits?.fiveHour
        let weekly = credits.windowLimits?.weekly

        let fiveHourPercent = windowPercent(used: fiveHour?.used, cap: fiveHour?.cap)
        let weeklyPercent = windowPercent(used: weekly?.used, cap: weekly?.cap)
        let hasWeeklyWindow = (weekly?.cap ?? 0) > 0

        let fiveHourReset = fiveHour?.resetAt.flatMap { parseEpochMillis($0) }
        let weeklyReset = weekly?.resetAt.flatMap { parseEpochMillis($0) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let fh = fiveHour, let cap = fh.cap, cap > 0 {
            breakdowns.append(UnifiedBreakdownItem(name: "5h Credits", usagePercent: fiveHourPercent, details: String(format: "%.2f / %.0f", fh.used ?? 0, cap)))
        }
        if let wk = weekly, let cap = wk.cap, cap > 0 {
            breakdowns.append(UnifiedBreakdownItem(name: "Weekly Credits", usagePercent: weeklyPercent, details: String(format: "%.2f / %.0f", wk.used ?? 0, cap)))
        }
        if let cost = summary?.totalCost {
            breakdowns.append(UnifiedBreakdownItem(name: "Period Cost", usagePercent: 0, details: String(format: "$%.2f", cost)))
        }

        let monthlyCredits = credits.credits?.monthlyCredits ?? 0
        let planLabel = userName ?? "Command Code"

        return UnifiedQuotaSnapshot(
            primaryPercent: fiveHourPercent,
            primaryLabel: "5h",
            primaryResetsAt: fiveHourReset,
            primaryLimitReached: fiveHour?.exceeded == true || fiveHourPercent >= 100,
            secondaryPercent: hasWeeklyWindow ? weeklyPercent : nil,
            secondaryLabel: hasWeeklyWindow ? "7d" : nil,
            secondaryResetsAt: weeklyReset,
            secondaryLimitReached: weekly?.exceeded == true || weeklyPercent >= 100,
            planTier: planLabel,
            extraUsageSpent: summary?.totalCost,
            extraUsageLimit: monthlyCredits > 0 ? monthlyCredits : nil,
            currency: "$",
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private func windowPercent(used: Double?, cap: Double?) -> Int {
        guard let used, let cap, cap > 0 else { return 0 }
        return Int(min(used / cap * 100, 100).rounded())
    }

    private func parseEpochMillis(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        // API returns ms when value is large, seconds otherwise
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        return Date(timeIntervalSince1970: value)
    }

    private struct CreditsResponse: Decodable {
        let credits: CreditBucket?
        let windowLimits: WindowLimits?

        struct CreditBucket: Decodable {
            let monthlyCredits: Double?
            let purchasedCredits: Double?
            let freeCredits: Double?
        }

        struct WindowLimits: Decodable {
            let limited: Bool?
            let fiveHour: WindowBucket?
            let weekly: WindowBucket?
        }

        struct WindowBucket: Decodable {
            let used: Double?
            let cap: Double?
            let exceeded: Bool?
            let resetAt: Double?
        }
    }

    private struct SummaryResponse: Decodable {
        let totalCost: Double?
        let totalCredits: Double?
        let periodBasis: String?
    }
}
