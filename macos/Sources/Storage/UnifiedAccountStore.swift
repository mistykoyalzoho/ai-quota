import Foundation
import Combine

extension Notification.Name {
    static let unifiedAccountsChanged = Notification.Name("app.aiquota.unifiedAccountsChanged")
    static let unifiedActiveAccountChanged = Notification.Name("app.aiquota.unifiedActiveAccountChanged")
}

final class UnifiedAccountStore: @unchecked Sendable {
    static let shared = UnifiedAccountStore()

    private let lock = NSLock()
    private var _accounts: [UnifiedAccount] = []
    private var _activeAccountId: String?
    private let fileURL: URL

    var allAccounts: [UnifiedAccount] {
        lock.lock()
        defer { lock.unlock() }
        return _accounts
    }

    var activeAccountId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _activeAccountId
    }

    var activeAccount: UnifiedAccount? {
        lock.lock()
        defer { lock.unlock() }
        if let id = _activeAccountId, let found = _accounts.first(where: { $0.id == id }) {
            return found
        }
        return _accounts.first
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AIQuota", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("accounts.json")

        load()

        if _accounts.isEmpty {
            autoDetectAndMergeCLI()
        }
    }

    func autoDetectAndMergeCLI() {
        let detected = CLICredentialsDetector.detectAllAccounts()
        guard !detected.isEmpty else { return }

        lock.lock()
        for newAcc in detected {
            if let existingIndex = _accounts.firstIndex(where: { existing in
                if existing.id == newAcc.id { return true }
                if existing.provider == newAcc.provider,
                   let email = newAcc.email, !email.isEmpty,
                   existing.email?.caseInsensitiveCompare(email) == .orderedSame {
                    return true
                }
                if existing.provider == .antigravity, newAcc.provider == .antigravity,
                   accountsShareAntigravityFingerprint(existing, newAcc) {
                    return true
                }
                return false
            }) {
                _accounts[existingIndex].authData = newAcc.authData
                if let email = newAcc.email, !email.isEmpty {
                    _accounts[existingIndex].email = email
                }
            } else {
                _accounts.append(newAcc)
            }
        }
        if _activeAccountId == nil, let first = _accounts.first {
            _activeAccountId = first.id
        }
        lock.unlock()

        save()
        notify()
    }

    func addOrUpdateAccount(_ account: UnifiedAccount) {
        lock.lock()
        if let idx = _accounts.firstIndex(where: { $0.id == account.id }) {
            _accounts[idx] = account
        } else {
            _accounts.append(account)
        }
        if _activeAccountId == nil {
            _activeAccountId = account.id
        }
        lock.unlock()

        save()
        notify()
    }

    func removeAccount(id: String) {
        lock.lock()
        _accounts.removeAll { $0.id == id }
        if _activeAccountId == id {
            _activeAccountId = _accounts.first?.id
        }
        lock.unlock()

        save()
        notify()
    }

    func setActiveAccount(id: String) {
        lock.lock()
        _activeAccountId = id
        lock.unlock()

        save()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .unifiedActiveAccountChanged, object: nil)
        }
    }

    func updateAccountUsage(id: String, usage: UnifiedQuotaSnapshot?, error: String?) {
        lock.lock()
        if let idx = _accounts.firstIndex(where: { $0.id == id }) {
            if let usage {
                _accounts[idx].lastUsage = usage
                _accounts[idx].lastError = nil
                _accounts[idx].lastRefreshedAt = Date()
            }
            if let error {
                _accounts[idx].lastError = error
                _accounts[idx].lastRefreshedAt = Date()
            }
        }
        lock.unlock()

        save()
        notify()
    }

    func setAccountNickname(id: String, nickname: String) {
        lock.lock()
        if let idx = _accounts.firstIndex(where: { $0.id == id }) {
            _accounts[idx].nickname = nickname
        }
        lock.unlock()

        save()
        notify()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .unifiedAccountsChanged, object: nil)
        }
    }

    private func accountsShareAntigravityFingerprint(_ lhs: UnifiedAccount, _ rhs: UnifiedAccount) -> Bool {
        guard case .antigravity(let lhsToken, _, _, _, _, _) = lhs.authData,
              case .antigravity(let rhsToken, _, _, _, _, _) = rhs.authData
        else { return false }
        let lhsFP = String(lhsToken.prefix(16))
        let rhsFP = String(rhsToken.prefix(16))
        return !lhsFP.isEmpty && lhsFP == rhsFP
    }

    private func save() {
        struct SavedFile: Codable {
            let activeAccountId: String?
            let accounts: [UnifiedAccount]
        }

        lock.lock()
        let payload = SavedFile(activeAccountId: _activeAccountId, accounts: _accounts)
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        struct SavedFile: Codable {
            let activeAccountId: String?
            let accounts: [UnifiedAccount]
        }

        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(SavedFile.self, from: data)
        else {
            return
        }

        lock.lock()
        _accounts = payload.accounts
        _activeAccountId = payload.activeAccountId ?? _accounts.first?.id
        lock.unlock()
    }
}
