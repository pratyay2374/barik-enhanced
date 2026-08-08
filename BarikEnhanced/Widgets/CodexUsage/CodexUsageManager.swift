import Foundation
import SwiftUI

private let codexUsageAccountFingerprintKey = "codex-usage-account-fingerprint"
private let codexUsageAcceptedRefreshKey = "codex-usage-accepted-auth-refresh"
private let codexUsageRememberedAccountsKey = "codex-usage-remembered-accounts"

// MARK: - Data Models

struct CodexUsageData {
    var primaryPercentage: Double = 0
    var primaryResetDate: Date?
    var primaryWindowMinutes: Int = 0

    var secondaryPercentage: Double = 0
    var secondaryResetDate: Date?
    var secondaryWindowMinutes: Int = 0

    var plan: String = "ChatGPT"
    var lastUpdated: Date = Date()
    var lastActivityDate: Date?
    var isAvailable: Bool = false
    /// The locally-logged-in account this snapshot belongs to, when known —
    /// used to remember/label Codex accounts across `codex login` switches.
    var accountFingerprint: String?
}

/// A Codex account Barik has seen locally logged in before. Codex's CLI only
/// ever holds one active login at a time, so this is bookkeeping/labeling —
/// not an independent credential Barik holds (see `CodexUsageManager`).
struct CodexRememberedAccount: Identifiable, Equatable, Codable {
    var id: String { fingerprint }
    let fingerprint: String
    var label: String
}

private struct CodexSessionEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Bucket?
        let secondary: Bucket?
        let credits: Credits?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case credits
            case planType = "plan_type"
        }
    }

    struct Bucket: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        // The backend has been observed sending `balance` as a numeric string
        // (e.g. "0") rather than a JSON number. A strict Double decode would
        // throw and silently kill the *entire* rate-limit event (this struct
        // is nested several levels deep under a `try?`), so accept either.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
            if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .balance) {
                balance = doubleValue
            } else if let stringValue = try? container.decodeIfPresent(String.self, forKey: .balance) {
                balance = Double(stringValue)
            } else {
                balance = nil
            }
        }
    }
}

private enum CodexUsageLoadState {
    case disconnected
    case connectedWithoutSnapshot(data: CodexUsageData)
    case connected(data: CodexUsageData)
    case failed
}

private struct CodexAuthState {
    let plan: String
    let accountID: String?
    let userID: String?
    let lastRefreshDate: Date?
    let subscriptionActiveStart: Date?

    var fingerprint: String? {
        let parts: [String] = [accountID, userID].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "|")
    }

    var switchCutoffDate: Date? {
        [lastRefreshDate, subscriptionActiveStart].compactMap { $0 }.max()
    }
}

// MARK: - Manager

@MainActor
final class CodexUsageManager: ObservableObject {
    static let shared = CodexUsageManager()

    @Published private(set) var usageData = CodexUsageData()
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var fetchFailed: Bool = false

    /// Every Codex account Barik has ever seen locally logged in, most-recent
    /// first-seen order preserved. Only `activeFingerprint`'s entry ever shows
    /// live usage — see `snapshot(for:)`.
    @Published private(set) var rememberedAccounts: [CodexRememberedAccount] = []
    @Published private(set) var activeFingerprint: String?
    /// The account the unified widget is currently *viewing* — independent of
    /// which one is actually logged in locally.
    @Published var selectedFingerprint: String?

    private var refreshTimer: Timer?
    private var recoveryTask: Task<Void, Never>?
    private var isFetching = false
    private var currentConfig: ConfigData = [:]

    private static let refreshInterval: TimeInterval = 60

    private init() {
        loadRememberedAccounts()
        selectedFingerprint = rememberedAccounts.first?.fingerprint
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ManualReloadTriggered"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func startUpdating(config: ConfigData) {
        currentConfig = config
        connectAndFetch()
    }

    func reconnectIfNeeded() {
        connectAndFetch()
    }

    func stopUpdating() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    func refresh() {
        fetchFailed = false
        connectAndFetch()
    }

    private func handleWake() {
        refreshTimer?.invalidate()
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            self?.connectAndFetch()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.connectAndFetch()
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.connectAndFetch()
        }
    }

    private func connectAndFetch() {
        // Wake and session notifications can arrive in a burst.  Session scans
        // are disk- and CPU-intensive, so allow only one to run at a time.
        guard !isFetching else { return }
        isFetching = true
        let planOverride = currentConfig["plan"]?.stringValue

        Task { [weak self] in
            let loadState = await Task.detached(priority: .utility) {
                Self.loadUsage(planOverride: planOverride)
            }.value

            guard let self else { return }
            self.isFetching = false

            switch loadState {
            case .disconnected:
                self.isConnected = false
                self.fetchFailed = false
                self.usageData = CodexUsageData()
                self.activeFingerprint = nil
                self.stopUpdating()

            case .connectedWithoutSnapshot(let data):
                self.isConnected = true
                self.fetchFailed = false
                self.usageData = data
                self.registerActiveAccount(fingerprint: data.accountFingerprint)
                self.scheduleRefreshTimer()

            case .connected(let data):
                self.isConnected = true
                self.fetchFailed = false
                self.usageData = data
                self.registerActiveAccount(fingerprint: data.accountFingerprint)
                self.scheduleRefreshTimer()

            case .failed:
                self.isConnected = true
                self.fetchFailed = true
                self.scheduleRefreshTimer()
            }
        }
    }

    // MARK: - Remembered accounts (bookkeeping only — Codex holds no credentials here)

    private func loadRememberedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: codexUsageRememberedAccountsKey),
              let decoded = try? JSONDecoder().decode([CodexRememberedAccount].self, from: data) else { return }
        rememberedAccounts = decoded
    }

    private func saveRememberedAccounts() {
        guard let data = try? JSONEncoder().encode(rememberedAccounts) else { return }
        UserDefaults.standard.set(data, forKey: codexUsageRememberedAccountsKey)
    }

    /// Sentinel used whenever Codex's local `auth.json` doesn't yield a real
    /// `chatgpt_account_id`/`chatgpt_user_id` fingerprint (some CLI/backend
    /// versions omit those claims). The account concept here is bookkeeping,
    /// not a credential — falling back to one fixed "local" entry keeps the
    /// widget showing real usage instead of a perpetually empty account list.
    private static let unknownAccountFingerprint = "local"

    private func registerActiveAccount(fingerprint: String?) {
        let resolved = (fingerprint?.isEmpty == false) ? fingerprint! : Self.unknownAccountFingerprint
        activeFingerprint = resolved
        if !rememberedAccounts.contains(where: { $0.fingerprint == resolved }) {
            let label = resolved == Self.unknownAccountFingerprint ? "Codex" : "Account \(rememberedAccounts.count + 1)"
            rememberedAccounts.append(CodexRememberedAccount(fingerprint: resolved, label: label))
            saveRememberedAccounts()
        }
        if selectedFingerprint == nil { selectedFingerprint = resolved }
    }

    // MARK: - Descriptor-facing API

    func accounts() -> [AgentAccount] {
        rememberedAccounts.map { account in
            AgentAccount(
                id: account.fingerprint,
                label: account.label,
                subtitle: account.fingerprint == activeFingerprint ? usageData.plan : nil,
                isRemovable: true,
                isActive: account.fingerprint == activeFingerprint
            )
        }
    }

    func selectAccount(_ fingerprint: String) {
        selectedFingerprint = fingerprint
    }

    func snapshot(for fingerprint: String) -> AccountUsageState {
        guard fingerprint == activeFingerprint else {
            return .unavailable(message: "Switch to this account by running `codex login`, then refresh.")
        }
        if usageData.isAvailable {
            var metrics = [
                UsageMetric(
                    id: "primary", icon: "clock", title: windowTitle(for: usageData.primaryWindowMinutes),
                    percentage: usageData.primaryPercentage, subtitle: nil,
                    resetDescription: usageData.primaryResetDate.map { "Resets in \(Self.resetTimeString($0))" }
                ),
            ]
            if usageData.secondaryWindowMinutes > 0 {
                metrics.append(UsageMetric(
                    id: "secondary", icon: "calendar", title: windowTitle(for: usageData.secondaryWindowMinutes),
                    percentage: usageData.secondaryPercentage, subtitle: nil,
                    resetDescription: usageData.secondaryResetDate.map { "Resets \(Self.resetTimeString($0))" }
                ))
            }
            return .available(AccountUsageSnapshot(planLabel: usageData.plan, metrics: metrics, lastUpdated: usageData.lastUpdated))
        }
        if fetchFailed {
            return .error(message: "Reading local Codex auth or session files failed.", lastUpdated: nil)
        }
        if !isConnected {
            return .unavailable(message: "Sign in to Codex (`codex login`) to view usage here.")
        }
        return .unavailable(message: "Run a Codex task first, then refresh.")
    }

    func renameAccount(_ fingerprint: String, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rememberedAccounts.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        rememberedAccounts[index].label = trimmed
        saveRememberedAccounts()
    }

    func removeAccount(_ fingerprint: String) {
        rememberedAccounts.removeAll { $0.fingerprint == fingerprint }
        saveRememberedAccounts()
        if selectedFingerprint == fingerprint {
            selectedFingerprint = activeFingerprint ?? rememberedAccounts.first?.fingerprint
        }
    }

    private func windowTitle(for minutes: Int) -> String {
        guard minutes > 0 else { return "Usage Window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-Day Window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-Hour Window" }
        return "\(minutes)-Minute Window"
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

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.connectAndFetch()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    nonisolated private static func loadUsage(planOverride: String?) -> CodexUsageLoadState {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let authURL = codexHome.appendingPathComponent("auth.json")
        let sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)

        guard let auth = readAuthState(from: authURL) else {
            return .disconnected
        }

        let plan = formatPlan(planOverride ?? auth.plan)
        let cutoffDate = accountSwitchCutoffDate(for: auth)

        let activity = latestTokenActivity(in: sessionsURL)

        guard let snapshot = latestUsageSnapshot(in: sessionsURL, after: cutoffDate) else {
            var data = CodexUsageData(plan: plan)
            data.lastActivityDate = activity
            data.accountFingerprint = auth.fingerprint
            return .connectedWithoutSnapshot(data: data)
        }

        persistAccountFingerprintIfNeeded(auth)

        let primaryPercentage = max(0, min(snapshot.bucket.usedPercent / 100, 1))
        let secondaryPct = snapshot.secondaryBucket.map { max(0, min($0.usedPercent / 100, 1)) } ?? 0
        var data = CodexUsageData(
            primaryPercentage: primaryPercentage,
            primaryResetDate: Date(timeIntervalSince1970: snapshot.bucket.resetsAt),
            primaryWindowMinutes: snapshot.bucket.windowMinutes,
            secondaryPercentage: secondaryPct,
            secondaryResetDate: snapshot.secondaryBucket.map { Date(timeIntervalSince1970: $0.resetsAt) },
            secondaryWindowMinutes: snapshot.secondaryBucket?.windowMinutes ?? 0,
            plan: formatPlan(planOverride ?? snapshot.plan ?? auth.plan),
            lastUpdated: snapshot.timestamp,
            lastActivityDate: activity,
            isAvailable: true
        )
        data.accountFingerprint = auth.fingerprint
        return .connected(data: data)
    }

    nonisolated private static func readAuthState(from authURL: URL) -> CodexAuthState? {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let authMode = json["auth_mode"] as? String
        if authMode == "apikey" || authMode == "api_key" {
            return CodexAuthState(
                plan: "API Key",
                accountID: nil,
                userID: nil,
                lastRefreshDate: parseTimestamp(json["last_refresh"] as? String ?? ""),
                subscriptionActiveStart: nil
            )
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            return nil
        }

        let accountID = tokens["account_id"] as? String
        let lastRefreshDate = parseTimestamp(json["last_refresh"] as? String ?? "")

        let candidateTokens = [
            tokens["id_token"] as? String,
            tokens["access_token"] as? String,
        ]

        for token in candidateTokens {
            guard let token,
                  let payload = decodeJWTPayload(token),
                  let auth = payload["https://api.openai.com/auth"] as? [String: Any],
                  let plan = auth["chatgpt_plan_type"] as? String,
                  !plan.isEmpty else {
                continue
            }
            return CodexAuthState(
                plan: plan,
                accountID: auth["chatgpt_account_id"] as? String ?? accountID,
                userID: auth["chatgpt_user_id"] as? String ?? auth["user_id"] as? String,
                lastRefreshDate: lastRefreshDate,
                subscriptionActiveStart: parseTimestamp(auth["chatgpt_subscription_active_start"] as? String ?? "")
            )
        }

        return nil
    }

    nonisolated private static func latestUsageSnapshot(in sessionsURL: URL, after cutoffDate: Date?) -> (bucket: CodexSessionEvent.Bucket, secondaryBucket: CodexSessionEvent.Bucket?, plan: String?, timestamp: Date)? {
        var latestSnapshot: (bucket: CodexSessionEvent.Bucket, secondaryBucket: CodexSessionEvent.Bucket?, plan: String?, timestamp: Date)?

        for fileURL in recentSessionFiles(in: sessionsURL) {
            guard let content = recentSessionContent(from: fileURL) else {
                continue
            }

            for line in content.split(separator: "\n").reversed() {
                guard line.contains(#""type":"token_count""#),
                      line.contains(#""rate_limits":"#) else {
                    continue
                }
                guard let event = decodeEvent(from: line),
                      event.type == "event_msg",
                      event.payload.type == "token_count",
                      let rateLimits = event.payload.rateLimits,
                      let bucket = rateLimits.primary,
                      let timestamp = parseTimestamp(event.timestamp) else {
                    continue
                }

                if let cutoffDate, timestamp < cutoffDate {
                    continue
                }

                if let latestSnapshot, latestSnapshot.timestamp >= timestamp {
                    continue
                }

                latestSnapshot = (
                    bucket: bucket,
                    secondaryBucket: rateLimits.secondary,
                    plan: rateLimits.planType,
                    timestamp: timestamp
                )
                break
            }
        }

        return latestSnapshot
    }

    nonisolated private static func accountSwitchCutoffDate(for auth: CodexAuthState) -> Date? {
        guard let fingerprint = auth.fingerprint else {
            return nil
        }

        let defaults = UserDefaults.standard
        guard let previousFingerprint = defaults.string(forKey: codexUsageAccountFingerprintKey) else {
            return auth.switchCutoffDate
        }

        guard previousFingerprint == fingerprint else {
            return auth.switchCutoffDate
        }

        guard defaults.object(forKey: codexUsageAcceptedRefreshKey) != nil else {
            return auth.switchCutoffDate
        }

        return nil
    }

    nonisolated private static func persistAccountFingerprintIfNeeded(_ auth: CodexAuthState) {
        guard let fingerprint = auth.fingerprint else {
            return
        }

        UserDefaults.standard.set(fingerprint, forKey: codexUsageAccountFingerprintKey)
        if let refreshDate = auth.switchCutoffDate {
            UserDefaults.standard.set(refreshDate.timeIntervalSince1970, forKey: codexUsageAcceptedRefreshKey)
        }
    }

    nonisolated private static func latestTokenActivity(in sessionsURL: URL) -> Date? {
        var latestActivity: Date?

        for fileURL in recentSessionFiles(in: sessionsURL) {
            guard let content = recentSessionContent(from: fileURL) else {
                continue
            }

            for line in content.split(separator: "\n").reversed() {
                guard line.contains(#""type":"token_count""#) else { continue }
                guard let event = decodeEvent(from: line),
                      event.type == "event_msg",
                      event.payload.type == "token_count",
                      let timestamp = parseTimestamp(event.timestamp) else {
                    continue
                }

                if let latestActivity, latestActivity >= timestamp {
                    break
                }

                latestActivity = timestamp
                break
            }
        }

        return latestActivity
    }

    nonisolated private static func recentSessionFiles(in sessionsURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.path > rhs.path
                }
                return lhsDate > rhsDate
            }
            .prefix(20)
            .map { $0 }
    }

    /// Codex session transcripts can be tens of megabytes.  The events we need
    /// are appended to JSONL files, so scanning a bounded tail avoids parsing
    /// the entire history on every refresh.
    nonisolated private static func recentSessionContent(from fileURL: URL) -> String? {
        let maximumBytes = 512 * 1024
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > UInt64(maximumBytes) ? fileSize - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A tail may start halfway through a JSONL record; discard that record.
        if offset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...firstNewline)
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func decodeEvent(from line: Substring) -> CodexSessionEvent? {
        guard let data = String(line).data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(CodexSessionEvent.self, from: data)
    }

    nonisolated private static func parseTimestamp(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue)
    }

    nonisolated private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (payload.count % 4)
        if padding < 4 {
            payload += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    nonisolated private static func formatPlan(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "free":
            "Free"
        case "plus":
            "Plus"
        case "pro":
            "Pro"
        case "team":
            "Team"
        case "business":
            "Business"
        case "enterprise":
            "Enterprise"
        case "api key":
            "API Key"
        default:
            rawValue
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}
