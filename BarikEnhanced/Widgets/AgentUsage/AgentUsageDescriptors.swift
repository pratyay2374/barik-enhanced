import SwiftUI

/// Builds the `[AgentProviderDescriptor]` list from the four concrete usage
/// managers. Cheap to call every `body` evaluation — it's just closures over
/// already-`@ObservedObject` managers, so no extra Combine plumbing is needed
/// for the unified UI to stay in sync with each manager's real state.
@MainActor
enum AgentUsageDescriptors {
    static func build(
        config: ConfigData,
        claude: ClaudeUsageManager,
        codex: CodexUsageManager,
        openCode: OpenCodeUsageManager,
        cursor: CursorUsageManager
    ) -> [AgentProviderDescriptor] {
        [claudeDescriptor(claude), codexDescriptor(codex), openCodeDescriptor(openCode), cursorDescriptor(cursor)]
    }

    /// Per-provider config sub-namespace, e.g. `[widgets.default.agent-usage.claude]`.
    static func providerConfig(_ config: ConfigData, providerID: String) -> ConfigData {
        config[providerID]?.dictionaryValue ?? [:]
    }

    private static func claudeDescriptor(_ claude: ClaudeUsageManager) -> AgentProviderDescriptor {
        AgentProviderDescriptor(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "Claude",
            iconAssetName: "ClaudeIcon",
            monogramLetter: nil,
            sfSymbolFallback: "sparkle",
            brandColor: Color(red: 0.89, green: 0.45, blue: 0.29),
            accounts: { claude.accounts() },
            selectedAccountID: { claude.selectedAccountID },
            selectAccount: { claude.selectedAccountID = $0 },
            usageState: { claude.snapshot(for: $0) },
            refresh: { claude.refresh(accountID: $0) },
            addAccount: { claude.beginAddAccount() },
            renameAccount: { claude.renameAccount($0, to: $1) },
            removeAccount: { claude.removeAccount($0) },
            signOut: { claude.removeAccount($0) },
            reauthAccount: { claude.beginReauth(accountID: $0) },
            overviewRow: { overviewRow(providerID: "claude", accounts: claude.accounts(), selectedID: claude.selectedAccountID, state: { claude.snapshot(for: $0) }) }
        )
    }

    private static func codexDescriptor(_ codex: CodexUsageManager) -> AgentProviderDescriptor {
        AgentProviderDescriptor(
            id: "codex",
            displayName: "Codex",
            shortLabel: "Codex",
            iconAssetName: "CodexIcon",
            monogramLetter: nil,
            sfSymbolFallback: "terminal",
            brandColor: .blue,
            accounts: { codex.accounts() },
            selectedAccountID: { codex.selectedFingerprint },
            selectAccount: { codex.selectAccount($0) },
            usageState: { codex.snapshot(for: $0) },
            refresh: { _ in codex.refresh() },
            addAccount: { codex.refresh() },
            renameAccount: { codex.renameAccount($0, to: $1) },
            removeAccount: { codex.removeAccount($0) },
            signOut: nil,
            reauthAccount: nil,
            overviewRow: { overviewRow(providerID: "codex", accounts: codex.accounts(), selectedID: codex.selectedFingerprint, state: { codex.snapshot(for: $0) }) }
        )
    }

    private static func openCodeDescriptor(_ openCode: OpenCodeUsageManager) -> AgentProviderDescriptor {
        AgentProviderDescriptor(
            id: "opencode",
            displayName: "OpenCode",
            shortLabel: "OpenCode",
            iconAssetName: nil,
            monogramLetter: "O",
            sfSymbolFallback: "terminal",
            brandColor: Color(red: 0.2, green: 0.8, blue: 0.5),
            accounts: { openCode.accounts() },
            selectedAccountID: { OpenCodeUsageManager.localAccountID },
            selectAccount: { _ in },
            usageState: { openCode.snapshot(for: $0) },
            refresh: { _ in openCode.refresh() },
            addAccount: nil,
            renameAccount: nil,
            removeAccount: nil,
            signOut: nil,
            reauthAccount: nil,
            overviewRow: { overviewRow(providerID: "opencode", accounts: openCode.accounts(), selectedID: OpenCodeUsageManager.localAccountID, state: { openCode.snapshot(for: $0) }) }
        )
    }

    private static func cursorDescriptor(_ cursor: CursorUsageManager) -> AgentProviderDescriptor {
        AgentProviderDescriptor(
            id: "cursor",
            displayName: "Cursor",
            shortLabel: "Cursor",
            iconAssetName: nil,
            monogramLetter: "C",
            sfSymbolFallback: "cursorarrow",
            brandColor: .purple,
            accounts: { cursor.accounts() },
            selectedAccountID: { CursorUsageManager.placeholderAccountID },
            selectAccount: { _ in },
            usageState: { cursor.snapshot(for: $0) },
            refresh: { cursor.refresh(accountID: $0) },
            addAccount: nil,
            renameAccount: nil,
            removeAccount: nil,
            signOut: nil,
            reauthAccount: nil,
            overviewRow: { AgentOverviewRow(providerID: "cursor", accountLabel: "Cursor", headlinePercentage: nil, isNearLimit: false, statusMessage: "Coming soon") }
        )
    }

    private static func overviewRow(
        providerID: String,
        accounts: [AgentAccount],
        selectedID: String?,
        state: (String) -> AccountUsageState
    ) -> AgentOverviewRow? {
        guard let accountID = selectedID ?? accounts.first?.id else {
            return AgentOverviewRow(providerID: providerID, accountLabel: "Not connected", headlinePercentage: nil, isNearLimit: false, statusMessage: "Add an account to get started")
        }
        let label = accounts.first(where: { $0.id == accountID })?.label ?? accountID
        switch state(accountID) {
        case .available(let snapshot):
            let pct = snapshot.metrics.first?.percentage
            return AgentOverviewRow(providerID: providerID, accountLabel: label, headlinePercentage: pct, isNearLimit: (pct ?? 0) >= 0.8, statusMessage: nil)
        case .loading:
            return AgentOverviewRow(providerID: providerID, accountLabel: label, headlinePercentage: nil, isNearLimit: false, statusMessage: "Loading…")
        case .authRequired:
            return AgentOverviewRow(providerID: providerID, accountLabel: label, headlinePercentage: nil, isNearLimit: false, statusMessage: "Sign in again")
        case .unavailable(let message), .error(let message, _):
            return AgentOverviewRow(providerID: providerID, accountLabel: label, headlinePercentage: nil, isNearLimit: false, statusMessage: message)
        }
    }
}
