import SwiftUI

// MARK: - Shared, provider-agnostic usage models
//
// Every concrete manager (ClaudeUsageManager, CodexUsageManager,
// OpenCodeUsageManager, CursorUsageManager) keeps its own real fetch logic and
// its own provider-specific data struct. These types are only the adapter
// layer the unified "AI Agent Usage" UI reads — see `AgentProviderDescriptor`.

/// One account under a coding-agent provider (e.g. "Personal" under Claude Code).
struct AgentAccount: Identifiable, Equatable {
    var id: String
    var label: String
    /// Provider-specific badge text shown next to the label (e.g. plan name).
    var subtitle: String?
    /// False for providers with exactly one implicit account (OpenCode today).
    var isRemovable: Bool = true
    /// True when this is the account whose data is actually live right now
    /// (relevant for Codex, where only the locally logged-in account has data).
    var isActive: Bool = true
}

/// A single usage window/limit for an account, kept flexible per doc section 7
/// so providers aren't forced into identical metrics.
struct UsageMetric: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// 0...1, nil when this provider has no percentage concept for this metric.
    let percentage: Double?
    /// Optional secondary line under the title/percentage row, e.g. a cost string.
    let subtitle: String?
    /// Precomputed friendly reset string, e.g. "Resets in 1h 43m".
    let resetDescription: String?
}

struct AccountUsageSnapshot {
    let planLabel: String?
    let metrics: [UsageMetric]
    let lastUpdated: Date
}

/// Where an account's usage view currently stands. Every case is honest about
/// what is/isn't known — never a fabricated 0% (doc section 13).
enum AccountUsageState {
    case loading
    case authRequired(message: String)
    case unavailable(message: String)
    case error(message: String, lastUpdated: Date?)
    case available(AccountUsageSnapshot)
}

/// Compact per-provider summary row for the overview mode (doc section 10).
struct AgentOverviewRow {
    let providerID: String
    let accountLabel: String
    let headlinePercentage: Double?
    let isNearLimit: Bool
    let statusMessage: String?
}
