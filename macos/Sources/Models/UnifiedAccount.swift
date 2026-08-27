import Foundation

// MARK: - Breakdown Item
struct UnifiedBreakdownItem: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var usagePercent: Int
    var details: String?
}

// MARK: - Standardized Snapshot
struct UnifiedQuotaSnapshot: Codable, Sendable, Equatable {
    var primaryPercent: Int             // Primary usage percentage (0-100+)
    var primaryLabel: String            // e.g. "5h" or "7d"
    var primaryResetsAt: Date?          // Reset time for primary bucket
    var primaryLimitReached: Bool

    var secondaryPercent: Int?          // Secondary usage percentage (optional)
    var secondaryLabel: String?         // e.g. "7d", "Top Model", "Credits"
    var secondaryResetsAt: Date?        // Reset time for secondary bucket
    var secondaryLimitReached: Bool

    var planTier: String?               // e.g. "Plus", "Team", "Pro", "SuperGrok Heavy", "Free"
    var extraUsageSpent: Double?        // e.g. $14.20
    var extraUsageLimit: Double?        // e.g. $50.00
    var currency: String?               // e.g. "$" or "USD"

    var breakdownItems: [UnifiedBreakdownItem]
    var fetchedAt: Date

    var isCritical: Bool {
        primaryLimitReached || (secondaryLimitReached) || primaryPercent >= 95 || (secondaryPercent ?? 0) >= 95
    }

    var isWarning: Bool {
        !isCritical && (primaryPercent >= 85 || (secondaryPercent ?? 0) >= 85)
    }
}

// MARK: - Unified Auth Payload
enum UnifiedAuthData: Codable, Sendable, Equatable {
    case codex(
        accessToken: String,
        refreshToken: String?,
        sessionToken: String?,
        accountID: String?,
        expiresAt: Date?
    )
    case claude(
        accessToken: String,
        refreshToken: String?,
        sessionKey: String?,
        orgID: String?,
        rateLimitTier: String?,
        expiresAt: Date?
    )
    case supergrok(
        accessToken: String,
        refreshToken: String?,
        ssoToken: String?,
        sub: String?,
        expiresAt: Date?
    )
    case cursor(
        accessToken: String,
        email: String?,
        membershipType: String?
    )
    case commandcode(
        apiKey: String,
        userId: String?,
        userName: String?
    )
    case copilot(
        accessToken: String,
        login: String?
    )
    case opencodego(
        apiKey: String,
        accountDescription: String?
    )
    case antigravity(
        accessToken: String,
        refreshToken: String?,
        email: String?,
        authMethod: String?,
        tokenSourcePath: String?,
        projectId: String?
    )
}

// MARK: - Unified Account
struct UnifiedAccount: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var provider: AIProvider
    var nickname: String
    var email: String?
    var authData: UnifiedAuthData
    var lastUsage: UnifiedQuotaSnapshot?
    var lastError: String?
    var lastRefreshedAt: Date?
    var isFreePlan: Bool = false

    var displayName: String {
        if !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname
        }
        if let email, !email.isEmpty {
            return email
        }
        return "\(provider.shortName) Account"
    }
}
