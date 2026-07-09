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

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    /// Where we are in the sign-in lifecycle. Drives which view the popup shows.
    enum AuthPhase {
        case signedOut     // no tokens — show "Sign in with Claude"
        case awaitingCode  // browser opened — show the paste-code field
        case signedIn      // tokens present — show usage / loading / error
    }

    @Published private(set) var usageData = ClaudeUsageData()
    @Published private(set) var authPhase: AuthPhase = .signedOut
    @Published private(set) var isAuthenticating = false
    @Published private(set) var fetchFailed: Bool = false
    @Published private(set) var errorMessage: String?

    /// Convenience for existing call sites / views.
    var isConnected: Bool { authPhase == .signedIn }

    private var refreshTimer: Timer?
    private var recoveryTask: Task<Void, Never>?
    private var currentConfig: ConfigData = [:]

    /// The OAuth tokens Barik obtained for itself. Stored in a keychain item we
    /// own (see load/save/clearTokens), so reads never prompt.
    private struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var plan: String

        /// True when the access token is at/near expiry and should be refreshed
        /// before the next API call. Unlike Claude Code's stored expiry, this
        /// one is OUR own and reliable, so we can act on it.
        var needsRefresh: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-120)
        }
    }

    private var tokens: Tokens?
    private var pkce: ClaudeOAuth.PKCE?

    private static let connectedKey = "claude-usage-connected"
    private static let refreshInterval: TimeInterval = 300
    private static let failedRetryInterval: TimeInterval = 120
    private static let maxBackoff: TimeInterval = 3600

    /// Service name for OUR OWN keychain item holding Barik's OAuth tokens.
    private static let tokenStoreService = "com.barik.claude-usage-oauth"

    /// When set, we're in a server-imposed rate-limit backoff and must not hit
    /// the usage API again until this time.
    private var rateLimitUntil: Date?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ManualReloadTriggered"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Lifecycle

    func startUpdating(config: ConfigData) {
        currentConfig = config
        if tokens == nil { tokens = loadTokens() }
        if tokens != nil {
            authPhase = .signedIn
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
            fetchData()
        } else {
            authPhase = .signedOut
            UserDefaults.standard.set(false, forKey: Self.connectedKey)
        }
    }

    func reconnectIfNeeded() {
        // Never disturb an in-progress sign-in (the popup may have been
        // reopened while the user is off in the browser).
        guard authPhase != .awaitingCode else { return }
        if tokens == nil { tokens = loadTokens() }
        if tokens != nil {
            authPhase = .signedIn
            fetchData()
        } else {
            authPhase = .signedOut
        }
    }

    func stopUpdating() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// The footer reload button and the loading/rate-limit paths.
    func refresh() {
        fetchFailed = false
        errorMessage = nil
        guard tokens != nil else { authPhase = .signedOut; return }
        authPhase = .signedIn
        fetchData()
    }

    /// The error view's "Retry" — same as refresh now that a truly dead token
    /// is recovered by the automatic refresh-token flow inside `fetchData`.
    func retry() {
        refresh()
    }

    // MARK: - Sign-in flow

    /// Starts sign-in: opens the browser to the Claude authorization page and
    /// switches the popup to the paste-code state.
    func beginSignIn() {
        let session = ClaudeOAuth.makePKCE()
        pkce = session
        errorMessage = nil
        guard let url = ClaudeOAuth.authorizationURL(pkce: session) else {
            errorMessage = "Couldn't build the sign-in URL."
            return
        }
        NSWorkspace.shared.open(url)
        authPhase = .awaitingCode
    }

    /// Re-opens the authorization page for the current sign-in attempt.
    func reopenSignInPage() {
        guard let session = pkce, let url = ClaudeOAuth.authorizationURL(pkce: session) else {
            beginSignIn()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func cancelSignIn() {
        pkce = nil
        errorMessage = nil
        authPhase = tokens != nil ? .signedIn : .signedOut
    }

    /// Exchanges the pasted authorization code for tokens.
    func submitCode(_ code: String) {
        guard let session = pkce else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Paste the code shown on the sign-in page."
            return
        }
        isAuthenticating = true
        errorMessage = nil
        Task {
            let result = await ClaudeOAuth.exchange(pastedCode: trimmed, pkce: session)
            self.isAuthenticating = false
            switch result {
            case .success(let resp):
                self.pkce = nil
                let plan = self.currentConfig["plan"]?.stringValue ?? "pro"
                let t = Tokens(
                    accessToken: resp.accessToken,
                    refreshToken: resp.refreshToken,
                    expiresAt: resp.expiresAt,
                    plan: plan
                )
                self.tokens = t
                self.saveTokens(t)
                self.authPhase = .signedIn
                UserDefaults.standard.set(true, forKey: Self.connectedKey)
                self.fetchData()

            case .failure:
                self.errorMessage = "Sign-in failed. Paste the full code from the page and try again."
                // Stay in .awaitingCode so the user can re-paste.
            }
        }
    }

    /// Discards Barik's tokens and returns to the signed-out state.
    func signOut() {
        tokens = nil
        pkce = nil
        clearTokens()
        rateLimitUntil = nil
        usageData = ClaudeUsageData()
        fetchFailed = false
        errorMessage = nil
        authPhase = .signedOut
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh scheduling

    private func handleWake() {
        guard tokens != nil, authPhase == .signedIn else { return }
        recoveryTask?.cancel()
        fetchData()
    }

    private func scheduleNextFetch(after interval: TimeInterval) {
        refreshTimer?.invalidate()
        let delay = max(interval, 1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fetchData() }
        }
        timer.tolerance = min(delay * 0.1, 30)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Data Fetching

    private func fetchData() {
        guard tokens != nil else { return }

        // Honor an active rate-limit backoff instead of hitting the API again.
        if let until = rateLimitUntil, Date() < until {
            fetchFailed = true
            errorMessage = rateLimitMessage(until: until)
            scheduleNextFetch(after: until.timeIntervalSinceNow)
            return
        }

        Task { await performFetch() }
    }

    private func performFetch() async {
        guard var current = tokens else { return }

        // Proactively refresh a soon-to-expire token — silent, no browser.
        if current.needsRefresh, let rt = current.refreshToken,
           let refreshed = await performRefresh(refreshToken: rt) {
            current = refreshed
        }

        let plan = currentConfig["plan"]?.stringValue ?? current.plan
        let result = await fetchUsageWithRetry(token: current.accessToken)

        switch result {
        case .success(let response):
            apply(response: response, plan: plan)
            rateLimitUntil = nil
            fetchFailed = false
            errorMessage = nil
            scheduleNextFetch(after: Self.refreshInterval)

        case .unauthorized:
            // Access token was rejected. Try one silent refresh + re-fetch
            // before making the user sign in again.
            if let rt = current.refreshToken,
               let refreshed = await performRefresh(refreshToken: rt) {
                let retry = await fetchUsageWithRetry(token: refreshed.accessToken)
                if case .success(let response) = retry {
                    apply(response: response, plan: plan)
                    rateLimitUntil = nil
                    fetchFailed = false
                    errorMessage = nil
                    scheduleNextFetch(after: Self.refreshInterval)
                    return
                }
            }
            // Refresh unavailable or also rejected — require a fresh sign-in.
            tokens = nil
            clearTokens()
            usageData = ClaudeUsageData()
            fetchFailed = false
            errorMessage = nil
            authPhase = .signedOut
            UserDefaults.standard.set(false, forKey: Self.connectedKey)
            refreshTimer?.invalidate()
            refreshTimer = nil

        case .rateLimited(let retryAfter):
            let delay = min(max(TimeInterval(retryAfter), Self.refreshInterval), Self.maxBackoff)
            let until = Date().addingTimeInterval(delay)
            rateLimitUntil = until
            fetchFailed = true
            errorMessage = rateLimitMessage(until: until)
            scheduleNextFetch(after: delay)

        case .failed:
            rateLimitUntil = nil
            fetchFailed = true
            errorMessage = "The request failed. Check your connection and try again."
            scheduleNextFetch(after: Self.failedRetryInterval)
        }
    }

    private func apply(response: UsageResponse, plan: String) {
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
        usageData = data
    }

    /// Refreshes the access token and persists the result. Returns the new
    /// tokens on success, nil on failure (caller decides whether to sign out).
    private func performRefresh(refreshToken: String) async -> Tokens? {
        let result = await ClaudeOAuth.refresh(refreshToken: refreshToken)
        guard case .success(let resp) = result else { return nil }
        var updated = tokens ?? Tokens(accessToken: resp.accessToken, refreshToken: resp.refreshToken, expiresAt: resp.expiresAt, plan: "pro")
        updated.accessToken = resp.accessToken
        if let rt = resp.refreshToken { updated.refreshToken = rt }
        updated.expiresAt = resp.expiresAt
        tokens = updated
        saveTokens(updated)
        return updated
    }

    private func rateLimitMessage(until: Date) -> String {
        let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
        return "Claude is rate limiting usage checks. Retrying in about \(minutes) min."
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

    // MARK: - Token store (our own keychain item)

    private func saveTokens(_ t: Tokens) {
        var payload: [String: Any] = [
            "accessToken": t.accessToken,
            "plan": t.plan,
        ]
        if let rt = t.refreshToken { payload["refreshToken"] = rt }
        if let exp = t.expiresAt { payload["expiresAt"] = exp.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
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

    private func loadTokens() -> Tokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
            kSecReturnData as String: true,
            // Never present UI for this read. On a stably-signed release build
            // it returns our token silently; on an ad-hoc debug build whose
            // identity isn't on the ACL it fails silently → sign-in screen.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String else {
            return nil
        }
        let refreshToken = json["refreshToken"] as? String
        let plan = json["plan"] as? String ?? "pro"
        let expiresAt = (json["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Tokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, plan: plan)
    }

    private func clearTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenStoreService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
