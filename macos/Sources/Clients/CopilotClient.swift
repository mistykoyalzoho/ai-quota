import Foundation

actor CopilotClient {
    static let shared = CopilotClient()

    private let session: URLSession
    private let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .copilot(let accessToken, let login) = account.authData else {
            throw NSError(domain: "CopilotClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Copilot credentials"])
        }

        guard !accessToken.isEmpty else {
            throw NSError(domain: "CopilotClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token. Run `gh auth login` or import Copilot CLI credentials."])
        }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CopilotClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CopilotClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Copilot HTTP \(http.statusCode). GitHub token may lack Copilot access."])
        }

        return try parseResponse(data, login: login)
    }

    private func parseResponse(_ data: Data, login: String?) throws -> UnifiedQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(CopilotUsageResponse.self, from: data)

        let premium = raw.quotaSnapshots?.premiumInteractions
        let chat = raw.quotaSnapshots?.chat

        let premiumPercent = quotaUsedPercent(snapshot: premium)
        let chatPercent = quotaUsedPercent(snapshot: chat)

        let resetDate = raw.quotaResetDate.flatMap { DateParsingHelper.parseISO8601($0) }
            ?? raw.quotaResetDate.flatMap { parseYMD($0) }

        var breakdowns: [UnifiedBreakdownItem] = []
        if let premium {
            breakdowns.append(breakdownItem(name: "Premium Requests", snapshot: premium))
        }
        if let chat, chat.unlimited != true {
            breakdowns.append(breakdownItem(name: "Chat", snapshot: chat))
        }
        if let completions = raw.quotaSnapshots?.completions, completions.unlimited != true {
            breakdowns.append(breakdownItem(name: "Completions", snapshot: completions))
        }

        let plan = raw.copilotPlan?.capitalized ?? "Copilot"
        let sku = raw.accessTypeSku ?? ""

        return UnifiedQuotaSnapshot(
            primaryPercent: premiumPercent,
            primaryLabel: "Premium",
            primaryResetsAt: resetDate,
            primaryLimitReached: premiumPercent >= 100,
            secondaryPercent: chat?.unlimited == true ? nil : (chatPercent > 0 ? chatPercent : nil),
            secondaryLabel: chat?.unlimited == true ? nil : "Chat",
            secondaryResetsAt: resetDate,
            secondaryLimitReached: chatPercent >= 100,
            planTier: "\(plan) (\(sku))",
            extraUsageSpent: nil,
            extraUsageLimit: nil,
            currency: "$",
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private func quotaUsedPercent(snapshot: QuotaSnapshot?) -> Int {
        guard let snapshot else { return 0 }
        if snapshot.unlimited == true { return 0 }
        if let pctRemaining = snapshot.percentRemaining {
            return Int(max(0, min(100, 100 - pctRemaining)).rounded())
        }
        let entitlement = snapshot.entitlement ?? 0
        let remaining = snapshot.remaining ?? Int(snapshot.quotaRemaining ?? 0)
        guard entitlement > 0 else { return 0 }
        let used = entitlement - remaining
        return Int(min(Double(used) / Double(entitlement) * 100, 100).rounded())
    }

    private func breakdownItem(name: String, snapshot: QuotaSnapshot) -> UnifiedBreakdownItem {
        let pct = quotaUsedPercent(snapshot: snapshot)
        let entitlement = snapshot.entitlement ?? 0
        let remaining = snapshot.remaining ?? Int(snapshot.quotaRemaining ?? 0)
        let details = snapshot.unlimited == true ? "Unlimited" : "\(remaining) / \(entitlement) left"
        return UnifiedBreakdownItem(name: name, usagePercent: pct, details: details)
    }

    private func parseYMD(_ value: String) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        return Calendar.current.date(from: comps)
    }

    private struct CopilotUsageResponse: Decodable {
        let login: String?
        let copilotPlan: String?
        let accessTypeSku: String?
        let quotaResetDate: String?
        let quotaSnapshots: QuotaSnapshots?

        struct QuotaSnapshots: Decodable {
            let chat: QuotaSnapshot?
            let completions: QuotaSnapshot?
            let premiumInteractions: QuotaSnapshot?
        }
    }

    private struct QuotaSnapshot: Decodable {
        let entitlement: Int?
        let remaining: Int?
        let quotaRemaining: Double?
        let percentRemaining: Double?
        let unlimited: Bool?
        let overagePermitted: Bool?
        let overageCount: Int?
    }
}
