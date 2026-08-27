import Foundation

actor AntigravityClient {
    static let shared = AntigravityClient()

    private let session: URLSession

    private let summaryEndpoints = [
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
    ]

    private let modelsEndpoints = [
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
    ]

    private let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(for account: UnifiedAccount) async throws -> UnifiedQuotaSnapshot {
        guard case .antigravity(let accessToken, let refreshToken, _, let authMethod, let tokenSourcePath, let cachedProjectId) = account.authData else {
            throw NSError(domain: "AntigravityClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid Antigravity credentials"])
        }

        guard !accessToken.isEmpty else {
            throw NSError(domain: "AntigravityClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "No Antigravity access token. Sign in via Antigravity or agy CLI, then re-import."])
        }

        var effectiveToken = accessToken
        var effectiveProjectId = cachedProjectId

        if let fresh = CLICredentialsDetector.refreshAntigravityCredentials(
            email: account.email,
            tokenSourcePath: tokenSourcePath,
            currentAccessToken: accessToken
        ) {
            effectiveToken = fresh.accessToken
            if let project = fresh.projectId {
                effectiveProjectId = project
            }
            if fresh.accessToken != accessToken || fresh.projectId != cachedProjectId {
                var updated = account
                updated.authData = .antigravity(
                    accessToken: fresh.accessToken,
                    refreshToken: fresh.refreshToken ?? refreshToken,
                    email: fresh.email ?? account.email,
                    authMethod: fresh.authMethod ?? authMethod,
                    tokenSourcePath: fresh.tokenSourcePath ?? tokenSourcePath,
                    projectId: effectiveProjectId
                )
                UnifiedAccountStore.shared.addOrUpdateAccount(updated)
            }
        }

        var tier: String?
        if effectiveProjectId == nil {
            let assist = try? await loadCodeAssist(accessToken: effectiveToken)
            effectiveProjectId = assist?.projectId
            tier = assist?.tier
        }

        if let summaryData = try? await fetchQuotaSummary(accessToken: effectiveToken, projectId: effectiveProjectId) {
            return try parseSummaryResponse(summaryData, planTier: tier)
        }

        if let modelsData = try? await fetchAvailableModels(accessToken: effectiveToken, projectId: effectiveProjectId) {
            return try parseModelsResponse(modelsData, planTier: tier)
        }

        throw NSError(
            domain: "AntigravityClient",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Antigravity quota unavailable. Token may be expired — open Antigravity or agy and sign in, then re-import."]
        )
    }

    // MARK: - Network

    private func loadCodeAssist(accessToken: String) async throws -> (projectId: String?, tier: String?) {
        var req = URLRequest(url: loadCodeAssistURL)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        applyHeaders(&req, accessToken: accessToken)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return (nil, nil)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let projectId = json["cloudaicompanionProject"] as? String
        let paidTier = json["paidTier"] as? [String: Any]
        let currentTier = json["currentTier"] as? [String: Any]
        let tier = (paidTier?["name"] as? String)
            ?? (paidTier?["id"] as? String)
            ?? (currentTier?["name"] as? String)
            ?? (currentTier?["id"] as? String)

        return (projectId, tier)
    }

    private func fetchQuotaSummary(accessToken: String, projectId: String?) async throws -> Data {
        var lastError: Error?
        for endpoint in summaryEndpoints {
            do {
                return try await postJSON(
                    urlString: endpoint,
                    accessToken: accessToken,
                    body: projectPayload(projectId)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Quota summary request failed"])
    }

    private func fetchAvailableModels(accessToken: String, projectId: String?) async throws -> Data {
        var lastError: Error?
        for endpoint in modelsEndpoints {
            do {
                return try await postJSON(
                    urlString: endpoint,
                    accessToken: accessToken,
                    body: projectPayload(projectId)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Models quota request failed"])
    }

    private func postJSON(urlString: String, accessToken: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyHeaders(&req, accessToken: accessToken)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network response"])
        }

        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AntigravityClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Antigravity HTTP \(http.statusCode). \(snippet.prefix(120))"]
            )
        }

        return data
    }

    private func applyHeaders(_ req: inout URLRequest, accessToken: String) {
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
    }

    private func projectPayload(_ projectId: String?) -> [String: Any] {
        if let projectId, !projectId.isEmpty {
            return ["project": projectId]
        }
        return [:]
    }

    // MARK: - Parsing

    private func parseSummaryResponse(_ data: Data, planTier: String?) throws -> UnifiedQuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid quota summary JSON"])
        }

        let groups = (json["groups"] as? [[String: Any]]) ?? []
        var fiveHourBuckets: [ParsedBucket] = []
        var weeklyBuckets: [ParsedBucket] = []
        var breakdowns: [UnifiedBreakdownItem] = []

        for group in groups {
            let groupName = (group["displayName"] as? String) ?? "Quota"
            let buckets = (group["buckets"] as? [[String: Any]]) ?? []
            for bucket in buckets {
                guard let parsed = parseBucket(bucket, groupName: groupName) else { continue }
                if parsed.isWeekly {
                    weeklyBuckets.append(parsed)
                } else {
                    fiveHourBuckets.append(parsed)
                }
                breakdowns.append(UnifiedBreakdownItem(
                    name: parsed.label,
                    usagePercent: parsed.usedPercent,
                    details: parsed.resetDescription
                ))
            }
        }

        if groups.isEmpty, let flatBuckets = json["buckets"] as? [[String: Any]] {
            for bucket in flatBuckets {
                guard let parsed = parseBucket(bucket, groupName: "Quota") else { continue }
                if parsed.isWeekly {
                    weeklyBuckets.append(parsed)
                } else {
                    fiveHourBuckets.append(parsed)
                }
                breakdowns.append(UnifiedBreakdownItem(
                    name: parsed.label,
                    usagePercent: parsed.usedPercent,
                    details: parsed.resetDescription
                ))
            }
        }

        let primary = fiveHourBuckets.max(by: { $0.usedPercent < $1.usedPercent })
        let secondary = weeklyBuckets.max(by: { $0.usedPercent < $1.usedPercent })

        guard primary != nil || secondary != nil else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No Antigravity quota buckets in response"])
        }

        let primaryPercent = primary?.usedPercent ?? secondary?.usedPercent ?? 0
        let secondaryPercent = (primary != nil && secondary != nil) ? secondary?.usedPercent : nil

        return UnifiedQuotaSnapshot(
            primaryPercent: primaryPercent,
            primaryLabel: "5h",
            primaryResetsAt: primary?.resetAt ?? secondary?.resetAt,
            primaryLimitReached: primaryPercent >= 100,
            secondaryPercent: secondaryPercent,
            secondaryLabel: secondaryPercent != nil ? "7d" : nil,
            secondaryResetsAt: secondary?.resetAt,
            secondaryLimitReached: (secondaryPercent ?? 0) >= 100,
            planTier: planTier ?? "Antigravity",
            extraUsageSpent: nil,
            extraUsageLimit: nil,
            currency: nil,
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private func parseModelsResponse(_ data: Data, planTier: String?) throws -> UnifiedQuotaSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any]
        else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid models quota JSON"])
        }

        var representativeUsed = 0
        var representativeReset: Date?
        var breakdowns: [UnifiedBreakdownItem] = []

        for (modelId, raw) in models {
            guard let model = raw as? [String: Any],
                  let quotaInfo = model["quotaInfo"] as? [String: Any]
            else { continue }

            let remainingFraction = extractRemainingFraction(from: quotaInfo)
            guard let remainingFraction else { continue }

            let used = usedPercent(fromRemainingFraction: remainingFraction)
            let displayName = (model["displayName"] as? String) ?? modelId
            let resetAt = (quotaInfo["resetTime"] as? String).flatMap { DateParsingHelper.parseISO8601($0) }

            breakdowns.append(UnifiedBreakdownItem(
                name: displayName,
                usagePercent: used,
                details: resetAt.map { ResetTimeTextFormatter.resetPhrase(resetAt: $0) }
            ))

            if used >= representativeUsed {
                representativeUsed = used
                representativeReset = resetAt
            }
        }

        guard !breakdowns.isEmpty else {
            throw NSError(domain: "AntigravityClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "No model quota data in Antigravity response"])
        }

        return UnifiedQuotaSnapshot(
            primaryPercent: representativeUsed,
            primaryLabel: "5h",
            primaryResetsAt: representativeReset,
            primaryLimitReached: representativeUsed >= 100,
            secondaryPercent: nil,
            secondaryLabel: nil,
            secondaryResetsAt: nil,
            secondaryLimitReached: false,
            planTier: planTier ?? "Antigravity",
            extraUsageSpent: nil,
            extraUsageLimit: nil,
            currency: nil,
            breakdownItems: breakdowns,
            fetchedAt: Date()
        )
    }

    private struct ParsedBucket {
        let label: String
        let usedPercent: Int
        let resetAt: Date?
        let resetDescription: String?
        let isWeekly: Bool
    }

    private func parseBucket(_ bucket: [String: Any], groupName: String) -> ParsedBucket? {
        let bucketId = (bucket["bucketId"] as? String) ?? ""
        let window = (bucket["window"] as? String) ?? bucketId
        let displayName = (bucket["displayName"] as? String) ?? groupName

        let remainingFraction = extractRemainingFraction(from: bucket)
        guard let remainingFraction else { return nil }

        let used = usedPercent(fromRemainingFraction: remainingFraction)
        let resetAt = (bucket["resetTime"] as? String).flatMap { DateParsingHelper.parseISO8601($0) }
        let isWeekly = isWeeklyWindow(window) || isWeeklyWindow(bucketId)

        let label: String
        if displayName.lowercased().contains("gemini") || groupName.lowercased().contains("gemini") {
            label = isWeekly ? "Gemini Weekly" : "Gemini 5h"
        } else if displayName.lowercased().contains("claude") || displayName.lowercased().contains("gpt") || groupName.lowercased().contains("claude") {
            label = isWeekly ? "Claude+GPT Weekly" : "Claude+GPT 5h"
        } else {
            label = "\(displayName) \(isWeekly ? "Weekly" : "5h")"
        }

        return ParsedBucket(
            label: label,
            usedPercent: used,
            resetAt: resetAt,
            resetDescription: resetAt.map { ResetTimeTextFormatter.resetPhrase(resetAt: $0) },
            isWeekly: isWeekly
        )
    }

    private func extractRemainingFraction(from object: [String: Any]) -> Double? {
        if let nested = object["remaining"] as? [String: Any],
           let fraction = nested["remainingFraction"] as? Double {
            return fraction
        }
        if let fraction = object["remainingFraction"] as? Double {
            return fraction
        }
        return nil
    }

    private func usedPercent(fromRemainingFraction fraction: Double) -> Int {
        let clamped = min(max(fraction, 0), 1)
        return Int(((1.0 - clamped) * 100).rounded())
    }

    private func isWeeklyWindow(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("weekly") || lower.contains("7d") || lower.contains("week") || lower.hasSuffix("-wk")
    }
}
