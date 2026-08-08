import SwiftUI

/// A read/write facade over one concrete usage manager (Claude/Codex/OpenCode/
/// Cursor), shaped so the unified widget/popup can iterate `[AgentProviderDescriptor]`
/// uniformly without generics or type erasure. Each concrete manager stays an
/// ordinary `@MainActor ObservableObject` singleton; the popup holds
/// `@ObservedObject` refs to all of them directly so SwiftUI still re-renders
/// correctly, and rebuilds this array fresh on every `body` evaluation (cheap —
/// it's just closures over already-observed managers).
struct AgentProviderDescriptor: Identifiable {
    let id: String
    let displayName: String
    /// Short form used only in the compact agent switcher, where "Claude Code"
    /// wraps to two lines and throws off the whole row's alignment.
    let shortLabel: String
    /// Assets.xcassets imageset name, when one exists.
    let iconAssetName: String?
    /// Single-letter monogram badge shown when there's no real asset (reads
    /// more like a logo placeholder than a generic SF Symbol would).
    let monogramLetter: String?
    /// SF Symbol used only if neither of the above is available.
    let sfSymbolFallback: String
    let brandColor: Color

    let accounts: () -> [AgentAccount]
    let selectedAccountID: () -> String?
    let selectAccount: (String) -> Void
    let usageState: (String) -> AccountUsageState
    let refresh: (String) -> Void

    /// Nil where "add" isn't a meaningful action (OpenCode's single implicit
    /// account, Cursor's stub).
    let addAccount: (() -> Void)?
    let renameAccount: ((String, String) -> Void)?
    let removeAccount: ((String) -> Void)?
    let signOut: ((String) -> Void)?
    /// Non-nil only where a dead session can be re-authenticated in place
    /// (Claude Code's OAuth today).
    let reauthAccount: ((String) -> Void)?

    let overviewRow: () -> AgentOverviewRow?
}
