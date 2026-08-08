import SwiftUI

struct AgentUsagePopup: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var coordinator = AgentUsageCoordinator.shared
    @ObservedObject private var claude = ClaudeUsageManager.shared
    @ObservedObject private var codex = CodexUsageManager.shared
    @ObservedObject private var openCode = OpenCodeUsageManager.shared
    @ObservedObject private var cursor = CursorUsageManager.shared

    @State private var showManageAccounts = false
    @State private var showSettings = false
    @State private var codeInput = ""

    private var descriptors: [AgentProviderDescriptor] {
        AgentUsageDescriptors.build(config: configProvider.config, claude: claude, codex: codex, openCode: openCode, cursor: cursor)
    }

    private var selectedDescriptor: AgentProviderDescriptor {
        descriptors.first { $0.id == coordinator.selectedProviderID } ?? descriptors[0]
    }

    private func thresholdConfiguration(for providerID: String) -> UsageThresholdConfiguration {
        UsageThresholdConfiguration(config: AgentUsageDescriptors.providerConfig(configProvider.config, providerID: providerID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBar

            if showManageAccounts {
                ManageAccountsView(descriptors: descriptors, onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) { showManageAccounts = false }
                })
                .transition(.opacity)
            } else if showSettings {
                UsageThresholdSettingsView(
                    title: selectedDescriptor.displayName,
                    widgetConfigKey: "default.agent-usage.\(selectedDescriptor.id)",
                    accentColor: selectedDescriptor.brandColor,
                    initialConfiguration: thresholdConfiguration(for: selectedDescriptor.id)
                )
                .agentUsageCard()
                .padding(.horizontal, AgentUsageStyle.outerPadding)
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
                    AgentSwitcherView(
                        descriptors: descriptors,
                        selectedID: coordinator.selectedProviderID,
                        onSelect: { id in
                            coordinator.selectedProviderID = id
                            coordinator.showOverview = false
                        }
                    )

                    Group {
                        if coordinator.showOverview {
                            AgentOverviewView(descriptors: descriptors, onSelect: { id in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    coordinator.selectedProviderID = id
                                    coordinator.showOverview = false
                                }
                            })
                            .id("overview")
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        } else {
                            mainContent
                                .id(selectedDescriptor.id)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                }
                .padding(.horizontal, AgentUsageStyle.outerPadding)
                .transition(.opacity)
            }
        }
        .padding(.bottom, AgentUsageStyle.outerPadding)
        .frame(width: 320)
        .background(Color.black)
        .onAppear {
            claude.reconnectIfNeeded()
            codex.reconnectIfNeeded()
            openCode.reconnectIfNeeded()
            cursor.reconnectIfNeeded()
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            Text("AI Agent Usage")
                .font(.system(size: 14, weight: .semibold))
            Spacer()

            if !showManageAccounts && !showSettings {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { coordinator.showOverview.toggle() }
                } label: {
                    Image(systemName: coordinator.showOverview ? "square.stack.3d.up" : "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help(coordinator.showOverview ? "Show selected agent" : "Show overview of all agents")
            }

            Menu {
                Button("Manage Accounts") {
                    showSettings = false
                    withAnimation(.easeInOut(duration: 0.2)) { showManageAccounts = true }
                }
                Button("Widget Settings") {
                    showManageAccounts = false
                    withAnimation(.easeInOut(duration: 0.2)) { showSettings = true }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, AgentUsageStyle.outerPadding)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .bottomTrailing) {
            if showManageAccounts || showSettings {
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showManageAccounts = false
                        showSettings = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.trailing, AgentUsageStyle.outerPadding)
                .padding(.bottom, -6)
                .pointingHandOnHover()
            }
        }
    }

    // MARK: - Main content (agent-specific)

    @ViewBuilder
    private var mainContent: some View {
        if selectedDescriptor.id == "claude" {
            if claude.addAccountPhase == .awaitingCode {
                claudeCodeEntryView
            } else if claude.accounts().isEmpty {
                claudeSignInView
            } else {
                accountDetailSection
            }
        } else {
            accountDetailSection
        }
    }

    private var accountDetailSection: some View {
        let descriptor = selectedDescriptor
        let accounts = descriptor.accounts()
        return VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
            if accounts.isEmpty {
                noAccountsView(for: descriptor)
            } else {
                AccountSwitcherView(descriptor: descriptor, showManageAccounts: $showManageAccounts)
                    .agentUsageCard(fill: AgentUsageStyle.subtleCardFill)
                let accountID = descriptor.selectedAccountID() ?? accounts[0].id
                AgentUsageDetailView(
                    descriptor: descriptor,
                    accountID: accountID,
                    thresholdConfiguration: thresholdConfiguration(for: descriptor.id)
                )
            }
        }
    }

    private func noAccountsView(for descriptor: AgentProviderDescriptor) -> some View {
        VStack(spacing: 14) {
            AgentIconView(descriptor: descriptor, size: 28)

            Text("No \(descriptor.displayName) accounts yet.")
                .font(.system(size: 11))
                .opacity(0.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let addAccount = descriptor.addAccount {
                Button(action: addAccount) {
                    Text("Add Account")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(descriptor.brandColor)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .agentUsageCard()
    }

    // MARK: - Claude sign-in (only provider with an in-app OAuth flow)

    private var claudeSignInView: some View {
        VStack(spacing: 14) {
            AgentIconView(descriptor: selectedDescriptor, size: 28)

            Text("Sign in with your Claude account to see your rate limit usage in the menu bar.")
                .font(.system(size: 11))
                .opacity(0.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                codeInput = ""
                claude.beginAddAccount()
            }) {
                Text("Sign in with Claude")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(selectedDescriptor.brandColor)
            .pointingHandOnHover()

            if let error = claude.addAccountError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Barik stores its own login securely in your keychain.")
                .font(.system(size: 10))
                .opacity(0.3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .agentUsageCard()
    }

    private var claudeCodeEntryView: some View {
        VStack(spacing: 12) {
            Text("Approve access in your browser, then paste the code shown on the page below.")
                .font(.system(size: 11))
                .opacity(0.6)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Paste authorization code", text: $codeInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { claude.submitCode(codeInput) }
                .disabled(claude.isAuthenticating)

            Button(action: { claude.submitCode(codeInput) }) {
                HStack(spacing: 6) {
                    if claude.isAuthenticating {
                        ProgressView().scaleEffect(0.6)
                    }
                    Text(claude.isAuthenticating ? "Signing in…" : "Complete Sign-in")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(selectedDescriptor.brandColor)
            .disabled(claude.isAuthenticating || codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .pointingHandOnHover()

            if let error = claude.addAccountError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Button("Reopen page") { claude.reopenSignInPage() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .opacity(0.6)
                    .pointingHandOnHover()
                Button("Cancel") {
                    codeInput = ""
                    claude.cancelSignIn()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .opacity(0.6)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .agentUsageCard()
    }
}
