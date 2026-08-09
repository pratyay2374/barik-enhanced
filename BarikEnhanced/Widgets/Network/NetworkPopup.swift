import SwiftUI

/// Secondary, in-place screens the popup can swap to — same "swap the body,
/// keep the one floating panel" pattern `AgentUsagePopup` uses for its
/// Manage Accounts / Settings screens.
private enum NetworkSecondaryView: Equatable {
    case none
    case password(WiFiNetwork)
    case details
}

/// Compact Wi‑Fi control center: current connection at a glance, nearby
/// networks to join directly, and a couple of common actions — replacing the
/// old flat "SSID + RSSI/Noise/Channel" readout.
struct NetworkPopup: View {
    @ObservedObject private var viewModel = NetworkStatusViewModel.shared
    @State private var secondary: NetworkSecondaryView = .none
    @State private var showAllNetworks = false
    /// Explanatory note shown above the password field when we land there
    /// because a *known* network's saved password stopped working, rather
    /// than because the user picked a brand-new secured network.
    @State private var passwordHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Group {
                switch secondary {
                case .none:
                    primaryContent
                        .transition(.opacity)
                case .password(let network):
                    NetworkPasswordView(
                        network: network,
                        joinState: viewModel.joinState,
                        hint: passwordHint,
                        onCancel: {
                            viewModel.dismissJoinResult()
                            passwordHint = nil
                            withAnimation(.easeInOut(duration: 0.2)) { secondary = .none }
                        },
                        onJoin: { password, remember in
                            viewModel.join(network: network, password: network.isSecured ? password : nil, remember: remember)
                        }
                    )
                    .padding(.horizontal, NetworkStyle.outerPadding)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .details:
                    NetworkDetailsView(
                        ssid: viewModel.ssid,
                        signalBars: viewModel.signalBars,
                        securityLabel: WiFiNetwork.detailedSecurityLabel(for: viewModel.currentSecurity),
                        ipAddress: viewModel.ipAddress,
                        frequencyLabel: viewModel.frequencyLabel,
                        onForget: {
                            viewModel.forget(ssid: viewModel.ssid)
                            withAnimation(.easeInOut(duration: 0.2)) { secondary = .none }
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) { secondary = .none }
                        }
                    )
                    .padding(.horizontal, NetworkStyle.outerPadding)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .padding(.bottom, NetworkStyle.outerPadding)
        }
        .frame(width: NetworkStyle.popupWidth)
        .background(Color.black)
        .onAppear { viewModel.popupDidAppear() }
        .onDisappear {
            viewModel.popupDidDisappear()
            secondary = .none
            showAllNetworks = false
            passwordHint = nil
        }
        .onChange(of: viewModel.joinState) { _, newValue in
            switch newValue {
            case .success:
                // Let the "Connected" confirmation show briefly, then return
                // to the primary list instead of leaving the password screen up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeInOut(duration: 0.2)) { secondary = .none }
                    viewModel.dismissJoinResult()
                }
            case .needsPassword(let ssid):
                // A known network's saved password stopped working — fall
                // back to asking for it instead of a dead-end failure.
                if let network = viewModel.availableNetworks.first(where: { $0.ssid == ssid }) {
                    passwordHint = "The saved password no longer works. Enter it again to reconnect."
                    withAnimation(.easeInOut(duration: 0.2)) { secondary = .password(network) }
                }
                viewModel.dismissJoinResult()
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            if secondary != .none {
                withAnimation(.easeInOut(duration: 0.2)) { secondary = .none }
            } else {
                NotificationCenter.default.post(name: .willHideWindow, object: nil)
            }
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Wi‑Fi")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if viewModel.wifiState != .notSupported && secondary == .none {
                Toggle("", isOn: Binding(
                    get: { viewModel.isWifiPowered },
                    set: { viewModel.setWifiPower($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, NetworkStyle.outerPadding)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Primary content

    @ViewBuilder
    private var primaryContent: some View {
        if viewModel.wifiState == .notSupported {
            unsupportedState
        } else if !viewModel.isWifiPowered {
            wifiOffState
        } else {
            VStack(alignment: .leading, spacing: NetworkStyle.cardSpacing) {
                currentNetworkSection
                otherNetworksSection
                ethernetRowIfNeeded
                settingsRow
            }
            .padding(.horizontal, NetworkStyle.outerPadding)
        }
    }

    private var unsupportedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.4))
            Text("Wi‑Fi Not Supported")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, NetworkStyle.outerPadding)
    }

    private var wifiOffState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.4))
            Text("Wi‑Fi is Off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Button {
                viewModel.setWifiPower(true)
            } label: {
                Text("Turn Wi‑Fi On")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .pointingHandOnHover()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, NetworkStyle.outerPadding)
    }

    // MARK: - Current network

    @ViewBuilder
    private var currentNetworkSection: some View {
        if isConnectedToWifi {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { secondary = .details }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(currentStatusColor.opacity(0.18)).frame(width: 30, height: 30)
                        if viewModel.wifiState == .connecting {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: currentStatusIcon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(currentStatusColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.ssid)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(currentStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 8)
                    WifiSignalIcon(strength: viewModel.signalBars, size: 15, activeColor: .white.opacity(0.8))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .networkCard(fill: NetworkStyle.subtleCardFill)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Not Connected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .padding(10)
            .networkCard(fill: NetworkStyle.subtleCardFill)
        }
    }

    private var isConnectedToWifi: Bool {
        viewModel.ssid != "Not connected" && viewModel.ssid != "No interface"
            && (viewModel.wifiState == .connected || viewModel.wifiState == .connectedWithoutInternet
                || viewModel.wifiState == .connecting)
    }

    private var currentStatusText: String {
        switch viewModel.wifiState {
        case .connecting: return "Connecting…"
        case .connectedWithoutInternet: return "No Internet"
        default: return "Connected"
        }
    }

    private var currentStatusIcon: String {
        viewModel.wifiState == .connectedWithoutInternet ? "wifi.exclamationmark" : "checkmark"
    }

    private var currentStatusColor: Color {
        switch viewModel.wifiState {
        case .connectedWithoutInternet: return .yellow
        case .connecting: return .yellow
        default: return .green
        }
    }

    // MARK: - Other networks

    @ViewBuilder
    private var otherNetworksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("OTHER NETWORKS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(0.5)
                if viewModel.isRefreshingList && !viewModel.availableNetworks.isEmpty {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                }
                Spacer()
                Button {
                    viewModel.refreshNetworks()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
                .help("Refresh networks")
            }

            networkListBody
        }
    }

    @ViewBuilder
    private var networkListBody: some View {
        switch viewModel.listState {
        case .idle:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Searching for networks…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        case .scanning where viewModel.availableNetworks.isEmpty:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Searching for networks…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        case .empty:
            emptyOrErrorState(message: "No Networks Found")
        case .error(let message):
            emptyOrErrorState(message: message)
        default:
            let rows = showAllNetworks
                ? viewModel.availableNetworks
                : Array(viewModel.availableNetworks.prefix(NetworkStyle.collapsedNetworkRowCount))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { network in
                        NetworkRowView(
                            network: network,
                            isConnecting: isConnecting(to: network),
                            onSelect: { select(network) }
                        )
                    }
                }
            }
            .frame(maxHeight: min(
                CGFloat(rows.count) * 34 + 4,
                NetworkStyle.networkListMaxHeight))

            if !showAllNetworks && viewModel.availableNetworks.count > NetworkStyle.collapsedNetworkRowCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllNetworks = true }
                } label: {
                    HStack {
                        Spacer()
                        Text("Show More Networks")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
    }

    private func emptyOrErrorState(message: String) -> some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Button("Try Again") { viewModel.refreshNetworks() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.blue.opacity(0.9))
                .pointingHandOnHover()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func isConnecting(to network: WiFiNetwork) -> Bool {
        if case .connecting(let ssid) = viewModel.joinState { return ssid == network.ssid }
        return false
    }

    private func select(_ network: WiFiNetwork) {
        if network.isSecured && !network.isKnown {
            // Never joined before (or previously forgotten) — needs a password.
            passwordHint = nil
            withAnimation(.easeInOut(duration: 0.2)) { secondary = .password(network) }
        } else {
            // Open, or already known — macOS already has what it needs; join
            // silently. `join(password: nil, ...)` on a known secured network
            // falls back to `.needsPassword` on its own if the saved
            // credential no longer works, handled in `onChange` above.
            viewModel.join(network: network, password: nil, remember: true)
        }
    }

    // MARK: - Ethernet (unrelated to Wi‑Fi, preserved from the previous popup)

    @ViewBuilder
    private var ethernetRowIfNeeded: some View {
        if viewModel.ethernetState != .notSupported {
            HStack(spacing: 8) {
                Image(systemName: ethernetIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(ethernetColor)
                Text("Ethernet: \(viewModel.ethernetState.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var ethernetIcon: String {
        switch viewModel.ethernetState {
        case .connected, .connectedWithoutInternet: return "network"
        default: return "network.slash"
        }
    }

    private var ethernetColor: Color {
        switch viewModel.ethernetState {
        case .connected: return .white.opacity(0.6)
        case .connectedWithoutInternet, .connecting: return .yellow
        default: return .white.opacity(0.3)
        }
    }

    // MARK: - Settings shortcut

    private var settingsRow: some View {
        Button {
            viewModel.openSystemWifiSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                Text("Wi‑Fi Settings")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .padding(.top, 2)
    }
}

struct NetworkPopup_Previews: PreviewProvider {
    static var previews: some View {
        NetworkPopup()
            .previewLayout(.sizeThatFits)
    }
}
