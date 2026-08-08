import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Data Models

struct ClaudeUsageData {
    var fiveHourPercentage: Double = 0
    var fiveHourResetDate: Date?

    var weeklyPercentage: Double = 0
    var weeklyResetDate: Date?

    var plan: String = "Pro"
    var lastUpdated: Date = Date()
    var isAvailable: Bool = false
}

private struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    struct UsageBucket: Codable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

// MARK: - Manager
//
// Supports multiple Claude accounts. Each account is Barik's own OAuth token
// set, stored as its own Keychain item (same service, keyed by `kSecAttrAccount`
// = accountID), so reads never prompt and accounts don't collide. A legacy
// single-account item (saved before multi-account support, with an empty
// account attribute) is migrated in place the first time it's found.
@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    /// Sign-in lifecycle for the "add account" flow. Independent from any
    /// individual account's live/dead state — see `AccountRecord.authRequired`.
    enum AddAccountPhase {
        case idle
        case awaitingCode  // browser opened — show the paste-code field
    }

    private struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var plan: String

        var needsRefresh: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-120)
        }
    }

    private struct AccountRecord {
        var id: String
        var label: String
        var tokens: Tokens
        var usageData = ClaudeUsageData()
        var authRequired = false
        var fetchFailed = false
        var errorMessage: String?
        var rateLimitUntil: Date?
        var refreshTimer: Timer?
    }

    @Published private(set) var accountOrder: [String] = []
    private var accountRecords: [String: AccountRecord] = [:] {
        didSet { objectWillChange.send() }
    }
    @Published var selectedAccountID: String?

    @Published private(set) var addAccountPhase: AddAccountPhase = .idle
    @Published private(set) var isAuthenticating = false
    @Published private(set) var addAccountError: String?

    private var currentConfig: ConfigData = [:]
    private var pkce: ClaudeOAuth.PKCE?
    /// Non-nil while re-authenticating an existing (dead-token) account rather
    /// than adding a brand-new one.
    private var reauthAccountID: String?

    private static let connectedKey = "claude-usage-connected"
    private static let orderKey = "claude-usage-account-order"
    private static let refreshInterval: TimeInterval = 300
    private static let failedRetryInterval: TimeInterval = 120
    private static let maxBackoff: TimeInterval = 3600
    private static let tokenStoreService = "com.barik.claude-usage-oauth"

    var hasAccounts: Bool { !accountOrder.isEmpty }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleWake() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleWake() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleWake() } }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ManualReloadTriggered"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshAll() } }
    }

    // MARK: - Lifecycle

    func startUpdating(config: ConfigData) {
        currentConfig = config
        if accountRecords.isEmpty {
            loadAccountsFromKeychain()
        }
        if selectedAccountID == nil {
            selectedAccountID = accountOrder.first
        }
        UserDefaults.standard.set(!accountOrder.isEmpty, forKey: Self.connectedKey)
        for id in accountOrder { fetchData(accountID: id) }
    }

    func reconnectIfNeeded() {
        guard addAccountPhase != .awaitingCode else { return }
        if accountRecords.isEmpty {
            loadAccountsFromKeychain()
            if selectedAccountID == nil { selectedAccountID = accountOrder.first }
        }
        for id in accountOrder { fetchData(accountID: id) }
    }

    func stopUpdating() {
        for id in accountOrder { accountRecords[id]?.refreshTimer?.invalidate() }
    }

    private func refreshAll() {
        for id in accountOrder { refresh(accountID: id) }
    }

    /// The footer reload button and the loading/rate-limit paths.
    func refresh(accountID: String) {
        guard accountRecords[accountID] != nil else { return }
        accountRecords[accountID]?.fetchFailed = false
        accountRecords[accountID]?.errorMessage = nil
        fetchData(accountID: accountID)
    }

    func retry(accountID: String) {
        refresh(accountID: accountID)
    }

    // MARK: - Descriptor-facing read API

    func accounts() -> [AgentAccount] {
        accountOrder.compactMap { id in
            guard let record = accountRecords[id] else { return nil }
            return AgentAccount(
                id: id,
                label: record.label,
                subtitle: record.usageData.isAvailable ? record.usageData.plan : nil
            )
        }
    }

    func snapshot(for accountID: String) -> AccountUsageState {
        guard let record = accountRecords[accountID] else { return .unavailable(message: "No account selected.") }
        if record.authRequired {
            return .authRequired(message: "Your Claude session expired.")
        }
        if record.usageData.isAvailable {
            let metrics = [
                UsageMetric(
                    id: "5h", icon: "clock", title: "5-Hour Window",
                    percentage: record.usageData.fiveHourPercentage,
                    subtitle: nil,
                    resetDescription: record.usageData.fiveHourResetDate.map { "Resets in \(Self.resetTimeString($0))" }
                ),
                UsageMetric(
                    id: "weekly", icon: "calendar", title: "Weekly",
                    percentage: record.usageData.weeklyPercentage,
                    subtitle: nil,
                    resetDescription: record.usageData.weeklyResetDate.map { "Resets \(Self.resetTimeString($0))" }
                ),
            ]
            return .available(AccountUsageSnapshot(
                planLabel: record.usageData.plan,
                metrics: metrics,
                lastUpdated: record.usageData.lastUpdated
            ))
        }
        if record.fetchFailed {
            return .error(message: record.errorMessage ?? "The request failed.", lastUpdated: record.usageData.lastUpdated)
        }
        return .loading
    }

    // MARK: - Sign-in flow

    /// Starts sign-in for a brand-new account.
    func beginAddAccount() {
        reauthAccountID = nil
        startSignIn()
    }

    /// Re-authenticates an existing account whose token died.
    func beginReauth(accountID: String) {
        reauthAccountID = accountID
        startSignIn()
    }

    private func startSignIn() {
        let session = ClaudeOAuth.makePKCE()
        pkce = session
        addAccountError = nil
        guard let url = ClaudeOAuth.authorizationURL(pkce: session) else {
            addAccountError = "Couldn't build the sign-in URL."
            return
        }
        NSWorkspace.shared.open(url)
        addAccountPhase = .awaitingCode
    }

    func reopenSignInPage() {
        guard let session = pkce, let url = ClaudeOAuth.authorizationURL(pkce: session) else {
            startSignIn()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func cancelSignIn() {
        pkce = nil
        reauthAccountID = nil
        addAccountError = nil
        addAccountPhase = .idle
    }

    /// Exchanges the pasted authorization code for tokens.
    func submitCode(_ code: String) {
        guard let session = pkce else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addAccountError = "Paste the code shown on the sign-in page."
            return
        }
        isAuthenticating = true
        addAccountError = nil
        Task {
            let result = await ClaudeOAuth.exchange(pastedCode: trimmed, pkce: session)
            self.isAuthenticating = false
            switch result {
            case .success(let resp):
                self.pkce = nil
                let plan = self.currentConfig["plan"]?.stringValue ?? "pro"
                let tokens = Tokens(
                    accessToken: resp.accessToken,
                    refreshToken: resp.refreshToken,
                    expiresAt: resp.expiresAt,
                    plan: plan
                )
                if let existingID = self.reauthAccountID, var record = self.accountRecords[existingID] {
                    record.tokens = tokens
                    record.authRequired = false
                    self.accountRecords[existingID] = record
                    self.saveTokens(tokens, accountID: existingID, label: record.label)
                    self.selectedAccountID = existingID
                    self.fetchData(accountID: existingID)
                } else {
                    let newID = UUID().uuidString
                    let label = "Account \(self.accountOrder.count + 1)"
                    let record = AccountRecord(id: newID, label: label, tokens: tokens)
                    self.accountRecords[newID] = record
                    self.accountOrder.append(newID)
                    self.persistAccountOrder()
                    self.saveTokens(tokens, accountID: newID, label: label)
                    self.selectedAccountID = newID
                    self.fetchData(accountID: newID)
                }
                self.reauthAccountID = nil
                self.addAccountPhase = .idle
                UserDefaults.standard.set(true, forKey: Self.connectedKey)

            case .failure:
                self.addAccountError = "Sign-in failed. Paste the full code from the page and try again."
            }
        }
    }

    // MARK: - Account management

    func renameAccount(_ accountID: String, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var record = accountRecords[accountID] else { return }
        record.label = trimmed
        accountRecords[accountID] = record
        saveTokens(record.tokens, accountID: accountID, label: trimmed)
    }

    /// Discards one account's tokens (Claude has no meaningful "sign out but
    /// keep remembered" state — signing out and removing are the same thing).
    func removeAccount(_ accountID: String) {
        accountRecords[accountID]?.refreshTimer?.invalidate()
        accountRecords.removeValue(forKey: accountID)
        accountOrder.removeAll { $0 == accountID }
        persistAccountOrder()
        clearTokens(accountID: accountID)
        if selectedAccountID == accountID {
            selectedAccountID = accountOrder.first
        }
        UserDefaults.standard.set(!accountOrder.isEmpty, forKey: Self.connectedKey)
    }

    // MARK: - Refresh scheduling

    private func handleWake() {
        for id in accountOrder where !(accountRecords[id]?.authRequired ?? true) {
            fetchData(accountID: id)
        }
    }

    private func scheduleNextFetch(accountID: String, after interval: TimeInterval) {
        accountRecords[accountID]?.refreshTimer?.invalidate()
        let delay = max(interval, 1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fetchData(accountID: accountID) }
        }
        timer.tolerance = min(delay * 0.1, 30)
        RunLoop.main.add(timer, forMode: .common)
        accountRecords[accountID]?.refreshTimer = timer
    }

    // MARK: - Data Fetching

    private func fetchData(accountID: String) {
        guard let record = accountRecords[accountID] else { return }

        if let until = record.rateLimitUntil, Date() < until {
            accountRecords[accountID]?.fetchFailed = true
            accountRecords[accountID]?.errorMessage = rateLimitMessage(until: until)
            scheduleNextFetch(accountID: accountID, after: until.timeIntervalSinceNow)
            return
        }

        Task { await performFetch(accountID: accountID) }
    }

    private func performFetch(accountID: String) async {
        guard var current = accountRecords[accountID]?.tokens else { return }

        if current.needsRefresh, let rt = current.refreshToken,
           let refreshed = await performRefresh(refreshToken: rt, accountID: accountID) {
            current = refreshed
        }

        let plan = currentConfig["plan"]?.stringValue ?? current.plan
        let result = await fetchUsageWithRetry(token: current.accessToken)

        switch result {
        case .success(let response):
            apply(response: response, plan: plan, accountID: accountID)
            accountRecords[accountID]?.rateLimitUntil = nil
            accountRecords[accountID]?.fetchFailed = false
            accountRecords[accountID]?.errorMessage = nil
            scheduleNextFetch(accountID: accountID, after: Self.refreshInterval)

        case .unauthorized:
            if let rt = current.refreshToken,
               let refreshed = await performRefresh(refreshToken: rt, accountID: accountID) {
                let retry = await fetchUsageWithRetry(token: refreshed.accessToken)
                if case .success(let response) = retry {
                    apply(response: response, plan: plan, accountID: accountID)
                    accountRecords[accountID]?.rateLimitUntil = nil
                    accountRecords[accountID]?.fetchFailed = false
                    accountRecords[accountID]?.errorMessage = nil
                    scheduleNextFetch(accountID: accountID, after: Self.refreshInterval)
                    return
                }
            }
            // Refresh unavailable or also rejected — this account needs sign-in again.
            accountRecords[accountID]?.authRequired = true
            accountRecords[accountID]?.usageData = ClaudeUsageData()
            accountRecords[accountID]?.fetchFailed = false
            accountRecords[accountID]?.errorMessage = nil
            accountRecords[accountID]?.refreshTimer?.invalidate()

        case .rateLimited(let retryAfter):
            let delay = min(max(TimeInterval(retryAfter), Self.refreshInterval), Self.maxBackoff)
            let until = Date().addingTimeInterval(delay)
            accountRecords[accountID]?.rateLimitUntil = until
            accountRecords[accountID]?.fetchFailed = true
            accountRecords[accountID]?.errorMessage = rateLimitMessage(until: until)
            scheduleNextFetch(accountID: accountID, after: delay)

        case .failed:
            accountRecords[accountID]?.rateLimitUntil = nil
            accountRecords[accountID]?.fetchFailed = true
            accountRecords[accountID]?.errorMessage = "The request failed. Check your connection and try again."
            scheduleNextFetch(accountID: accountID, after: Self.failedRetryInterval)
        }
    }

    private func apply(response: UsageResponse, plan: String, accountID: String) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var data = ClaudeUsageData()
        data.fiveHourPercentage = (response.fiveHour?.utilization ?? 0) / 100
        data.fiveHourResetDate = response.fiveHour.flatMap { bucket in
            bucket.resetsAt.flatMap { isoFormatter.date(from: $0) }
        }
        data.weeklyPercentage = (response.sevenDay?.utilization ?? 0) / 100
        data.weeklyResetDate = response.sevenDay.flatMap { bucket in
            bucket.resetsAt.flatMap { isoFormatter.date(from: $0) }
        }
        data.plan = plan.capitalized
        data.lastUpdated = Date()
        data.isAvailable = true
        accountRecords[accountID]?.usageData = data
    }

    private func performRefresh(refreshToken: String, accountID: String) async -> Tokens? {
        let result = await ClaudeOAuth.refresh(refreshToken: refreshToken)
        guard case .success(let resp) = result else { return nil }
        guard var updated = accountRecords[accountID]?.tokens else { return nil }
        updated.accessToken = resp.accessToken
        if let rt = resp.refreshToken { updated.refreshToken = rt }
        updated.expiresAt = resp.expiresAt
        accountRecords[accountID]?.tokens = updated
        saveTokens(updated, accountID: accountID, label: accountRecords[accountID]?.label ?? "Account")
        return updated
    }

    private func rateLimitMessage(until: Date) -> String {
        let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
        return "Claude is rate limiting usage checks. Retrying in about \(minutes) min."
    }

    private static func resetTimeString(_ date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        if interval <= 0 { return "soon" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "E h:mm a"
            return formatter.string(from: date)
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Usage API

    private func fetchUsageWithRetry(token: String) async -> FetchResult {
        for attempt in 0..<2 {
            let result = await fetchUsageFromAPI(token: token)
            switch result {
            case .success:
                return result
            case .unauthorized:
                return .unauthorized
            case .rateLimited(let retryAfter):
                guard attempt == 0, retryAfter > 0, retryAfter <= 180 else { return .rateLimited(retryAfter: retryAfter) }
                try? await Task.sleep(for: .seconds(retryAfter))
                continue
            case .failed:
                return .failed
            }
        }
        return .failed
    }

    private enum FetchResult {
        case success(UsageResponse)
        case unauthorized
        case rateLimited(retryAfter: Int)
        case failed
    }

    private func fetchUsageFromAPI(token: String) async -> FetchResult {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return .failed }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }

            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after")
                    .flatMap(Int.init) ?? 0
                return .rateLimited(retryAfter: retryAfter)
            }
            guard http.statusCode == 200 else { return .failed }

            if let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) {
                return .success(decoded)
            }
            return .failed
        } catch {
            return .failed
        }
    }

    // MARK: - Token store (our own keychain items, one per account)

    private func saveTokens(_ t: Tokens, accountID: String, label: String) {
        var payload: [String: Any] = [
            "accessToken": t.accessToken,
            "plan": t.plan,
            "label": label,
        ]
        if let rt = t.refreshToken { payload["refreshToken"] = rt }
        if let exp = t.expiresAt { payload["expiresAt"] = exp.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
            kSecAttrAccount as String: accountID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Loads every account stored under our service, migrating the legacy
    /// single-account item (empty `kSecAttrAccount`, predates multi-account
    /// support) to a real account id in place.
    private func loadAccountsFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        let savedOrder = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        var loaded: [String: AccountRecord] = [:]

        for item in items {
            guard let data = item[kSecAttrGeneric as String] as? Data ?? item[kSecValueData as String] as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["accessToken"] as? String else { continue }

            let refreshToken = json["refreshToken"] as? String
            let plan = json["plan"] as? String ?? "pro"
            let expiresAt = (json["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let tokens = Tokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, plan: plan)

            let rawAccountID = item[kSecAttrAccount as String] as? String ?? ""
            let label = json["label"] as? String ?? "Personal"

            if rawAccountID.isEmpty {
                // Legacy single-account item — migrate to a stable id.
                let newID = UUID().uuidString
                saveTokens(tokens, accountID: newID, label: label)
                clearTokens(accountID: "")
                loaded[newID] = AccountRecord(id: newID, label: label, tokens: tokens)
            } else {
                loaded[rawAccountID] = AccountRecord(id: rawAccountID, label: label, tokens: tokens)
            }
        }

        accountRecords = loaded
        // Preserve remembered order where possible, then append any unordered ids.
        var order = savedOrder.filter { loaded[$0] != nil }
        for id in loaded.keys where !order.contains(id) { order.append(id) }
        accountOrder = order
        persistAccountOrder()
    }

    private func persistAccountOrder() {
        UserDefaults.standard.set(accountOrder, forKey: Self.orderKey)
    }

    private func clearTokens(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
