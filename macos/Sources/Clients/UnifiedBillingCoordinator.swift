import Foundation

actor UnifiedBillingCoordinator {
    static let shared = UnifiedBillingCoordinator()

    private var inFlightTasks: [String: Task<UnifiedQuotaSnapshot, Error>] = [:]

    func fetch(for account: UnifiedAccount, force: Bool = false) async throws -> UnifiedQuotaSnapshot {
        let accountId = account.id

        if let existing = inFlightTasks[accountId] {
            return try await existing.value
        }

        let task = Task<UnifiedQuotaSnapshot, Error> {
            switch account.provider {
            case .codex:
                return try await CodexClient.shared.fetchUsage(for: account)
            case .claude:
                return try await ClaudeClient.shared.fetchUsage(for: account)
            case .supergrok:
                return try await SuperGrokClient.shared.fetchUsage(for: account)
            case .cursor:
                return try await CursorClient.shared.fetchUsage(for: account)
            case .commandcode:
                return try await CommandCodeClient.shared.fetchUsage(for: account)
            case .copilot:
                return try await CopilotClient.shared.fetchUsage(for: account)
        case .opencodego:
            return try await OpenCodeGoClient.shared.fetchUsage(for: account)
            case .antigravity:
                return try await AntigravityClient.shared.fetchUsage(for: account)
            }
        }

        inFlightTasks[accountId] = task

        do {
            let snapshot = try await task.value
            inFlightTasks.removeValue(forKey: accountId)
            UnifiedAccountStore.shared.updateAccountUsage(id: accountId, usage: snapshot, error: nil)
            return snapshot
        } catch {
            inFlightTasks.removeValue(forKey: accountId)
            UnifiedAccountStore.shared.updateAccountUsage(id: accountId, usage: nil, error: error.localizedDescription)
            throw error
        }
    }

    func refreshAll(accounts: [UnifiedAccount]) async {
        await withTaskGroup(of: Void.self) { group in
            for acc in accounts {
                group.addTask {
                    _ = try? await self.fetch(for: acc, force: true)
                }
            }
        }
    }
}
