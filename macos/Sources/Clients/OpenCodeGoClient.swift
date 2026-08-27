import Foundation

actor OpenCodeGoClient {
    static let shared = OpenCodeGoClient()

    private let session: URLSession
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .opencodego(let apiKey, let accountDescription) = account.authData else {
            throw NSError(domain: "OpenCodeGoClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenCode Go credentials"])
        }

        guard !apiKey.isEmpty else {
            throw NSError(domain: "OpenCodeGoClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "No OpenCode Go API key. Configure opencode-go in ~/.local/share/opencode/auth.json."])
        }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenCodeGoClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "OpenCodeGoClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenCode Go HTTP \(http.statusCode). API key may be invalid or expired."])
        }

        return try parseResponse(data, accountDescription: accountDescription)
    }

    private func parseResponse(_ data: Data, accountDescription: String?) throws -> UnifiedQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(OpenCodeGoUsageResponse.self, from: data)

        let rolling = raw.usage?.rolling
        let weekly = raw.usage?.weekly
        let monthly = raw.usage?.monthly

        let rollingPercent = Int((rolling?.percent ?? 0).rounded())
        let weeklyPercent = Int((weekly?.percent ?? 0).rounded())

        let rollingReset = rolling?.resetsAt.flatMap { DateParsingHelper.parseISO8601($0) }
        let weeklyReset = weekly?.resetsAt.flatMap { DateParsingHelper.parseISO8601($0) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let rolling {
            breakdowns.append(UnifiedBreakdownItem(name: "Rolling 5h", usagePercent: Int(rolling.percent?.rounded() ?? 0), details: rolling.status))
        }
        if let weekly {
            breakdowns.append(UnifiedBreakdownItem(name: "Weekly", usagePercent: Int(weekly.percent?.rounded() ?? 0), details: weekly.status))
        }
        if let monthly {
            breakdowns.append(UnifiedBreakdownItem(name: "Monthly", usagePercent: Int(monthly.percent?.rounded() ?? 0), details: monthly.status))
        }

        return UnifiedQuotaSnapshot(
            primaryPercent: rollingPercent,
            primaryLabel: "5h",
            primaryResetsAt: rollingReset,
            primaryLimitReached: rolling?.status == "exceeded" || rollingPercent >= 100,
            secondaryPercent: weekly != nil ? weeklyPercent : nil,
            secondaryLabel: weekly != nil ? "7d" : nil,
            secondaryResetsAt: weeklyReset,
            secondaryLimitReached: weekly?.status == "exceeded" || weeklyPercent >= 100,
            planTier: accountDescription ?? "OpenCode Go",
            extraUsageSpent: nil,
            extraUsageLimit: nil,
            currency: "$",
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private struct OpenCodeGoUsageResponse: Decodable {
        let usage: UsageWindows?

        struct UsageWindows: Decodable {
            let rolling: WindowBucket?
            let weekly: WindowBucket?
            let monthly: WindowBucket?
        }

        struct WindowBucket: Decodable {
            let status: String?
            let percent: Double?
            let resetsAt: String?
        }
    }
}
