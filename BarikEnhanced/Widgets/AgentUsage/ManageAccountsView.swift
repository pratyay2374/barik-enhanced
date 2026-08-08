import SwiftUI

/// Grouped-by-provider account management (doc section 8): rename, remove,
/// add, see which account is active — all in one screen reachable from any
/// agent's account switcher. Each provider is its own rounded "island".
struct ManageAccountsView: View {
    let descriptors: [AgentProviderDescriptor]
    let onClose: () -> Void

    @State private var renamingID: String?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
            HStack {
                Text("Manage Accounts")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
            .padding(.horizontal, AgentUsageStyle.outerPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
                    ForEach(descriptors) { descriptor in
                        providerSection(descriptor)
                    }
                }
                .padding(.horizontal, AgentUsageStyle.outerPadding)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 320)
        }
    }

    private func providerSection(_ descriptor: AgentProviderDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentIconView(descriptor: descriptor, size: 13)
                Text(descriptor.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.8)
            }

            let accounts = descriptor.accounts()
            if accounts.isEmpty {
                Text("No accounts yet.")
                    .font(.system(size: 11))
                    .opacity(0.4)
            }

            ForEach(accounts) { account in
                accountRow(descriptor, account)
            }

            if let addAccount = descriptor.addAccount {
                Button {
                    addAccount()
                } label: {
                    Text("+ Add Account")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(descriptor.brandColor)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentUsageCard()
    }

    private func accountRow(_ descriptor: AgentProviderDescriptor, _ account: AgentAccount) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isActive ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)

            if renamingID == account.id {
                TextField("Account name", text: $renameText, onCommit: {
                    descriptor.renameAccount?(account.id, renameText)
                    renamingID = nil
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            } else {
                Text(account.label)
                    .font(.system(size: 12))
                if let subtitle = account.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .opacity(0.4)
                }
            }

            Spacer()

            if descriptor.renameAccount != nil {
                Button {
                    renamingID = account.id
                    renameText = account.label
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .opacity(0.5)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            if account.isRemovable, let removeAccount = descriptor.removeAccount {
                Button {
                    removeAccount(account.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .opacity(0.5)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
        .padding(.vertical, 2)
    }
}
