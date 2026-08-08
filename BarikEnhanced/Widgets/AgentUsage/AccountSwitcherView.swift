import SwiftUI

/// Compact account picker for the currently-selected agent (doc section 5) —
/// a single "Label ▾" control rather than showing every account's usage at
/// once, so the popover stays short even with many accounts.
struct AccountSwitcherView: View {
    let descriptor: AgentProviderDescriptor
    @Binding var showManageAccounts: Bool

    @State private var isHovered = false

    private var accounts: [AgentAccount] { descriptor.accounts() }
    private var selectedID: String? { descriptor.selectedAccountID() ?? accounts.first?.id }
    private var selectedAccount: AgentAccount? { accounts.first { $0.id == selectedID } }

    var body: some View {
        HStack {
            Menu {
                ForEach(accounts) { account in
                    Button {
                        descriptor.selectAccount(account.id)
                    } label: {
                        if account.id == selectedID {
                            Label(account.label, systemImage: "checkmark")
                        } else {
                            Text(account.label)
                        }
                    }
                }
                if let addAccount = descriptor.addAccount {
                    if !accounts.isEmpty { Divider() }
                    Button("Add Account") { addAccount() }
                }
                Divider()
                Button("Manage Accounts") { showManageAccounts = true }
            } label: {
                HStack(spacing: 5) {
                    Text(selectedAccount?.label ?? "No account")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    // A picker-style up/down glyph reads more clearly as
                    // "choose from a list" than a plain down chevron, and
                    // nudges up slightly on hover for a touch of life.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.55))
                        .offset(y: isHovered ? -1 : 0)
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHovered = $0 }
            .pointingHandOnHover()

            Spacer()

            if let subtitle = selectedAccount?.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(descriptor.brandColor.opacity(0.3))
                    .foregroundColor(descriptor.brandColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
