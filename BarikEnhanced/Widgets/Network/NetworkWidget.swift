import SwiftUI

/// Widget for the menu, displaying Wi‑Fi and Ethernet icons.
struct NetworkWidget: View {
    @ObservedObject private var viewModel = NetworkStatusViewModel.shared
    @State private var rect: CGRect = .zero

    var body: some View {
        HStack(spacing: 15) {
            if shouldShowWifi {
                wifiIcon
                    .symbolEffect(
                        .variableColor.iterative.reversing,
                        options: .repeating,
                        isActive: viewModel.wifiState == .connecting
                    )
                    .onTapGesture {
                        MenuBarPopup.show(rect: rect, id: "network") { NetworkPopup() }
                    }
            }
            if viewModel.ethernetState != .notSupported {
                ethernetIcon
                    .onTapGesture {
                        MenuBarPopup.show(rect: rect, id: "network") { NetworkPopup() }
                    }
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rect = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, newValue in
                        rect = newValue
                    }
            }
        )
        .contentShape(Rectangle())
        .font(.system(size: 15))
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
    }

    /// Show the Wi-Fi icon whenever there's Wi-Fi hardware at all. Wi-Fi being
    /// turned off is itself a state worth surfacing (greyed out, per the icon
    /// below) rather than hiding — the icon is how you'd turn it back on.
    /// The one case still hidden: Wi-Fi merely "available but not in use"
    /// while Ethernet is the active connection, to avoid a redundant icon.
    private var shouldShowWifi: Bool {
        guard viewModel.hasWifiHardware else { return false }
        if !viewModel.isWifiPowered { return true }
        switch viewModel.wifiState {
        case .disconnected:
            return viewModel.ethernetState != .connected
                && viewModel.ethernetState != .connectedWithoutInternet
        default:
            // connected, connecting, connectedWithoutInternet, disabled, notSupported — always show
            return true
        }
    }

    private var wifiIcon: some View {
        if !viewModel.isWifiPowered {
            return Image(systemName: "wifi.slash")
                .foregroundColor(.gray.opacity(0.5))
        }
        if viewModel.ssid == "Not connected" {
            return Image(systemName: "wifi.slash")
                .foregroundColor(.red)
        }
        switch viewModel.wifiState {
        case .connected:
            return Image(systemName: "wifi")
                .foregroundColor(.foregroundOutside)
        case .connecting:
            return Image(systemName: "wifi")
                .foregroundColor(.yellow)
        case .connectedWithoutInternet:
            return Image(systemName: "wifi.exclamationmark")
                .foregroundColor(.yellow)
        case .disconnected:
            return Image(systemName: "wifi.slash")
                .foregroundColor(.gray)
        case .disabled:
            return Image(systemName: "wifi.slash")
                .foregroundColor(.red)
        case .notSupported:
            return Image(systemName: "wifi.exclamationmark")
                .foregroundColor(.gray)
        }
    }

    private var ethernetIcon: some View {
        switch viewModel.ethernetState {
        case .connected:
            return Image(systemName: "network")
                .foregroundColor(.primary)
        case .connectedWithoutInternet:
            return Image(systemName: "network")
                .foregroundColor(.yellow)
        case .connecting:
            return Image(systemName: "network.slash")
                .foregroundColor(.yellow)
        case .disconnected:
            return Image(systemName: "network.slash")
                .foregroundColor(.red)
        case .disabled, .notSupported:
            return Image(systemName: "questionmark.circle")
                .foregroundColor(.gray)
        }
    }
}

struct NetworkWidget_Previews: PreviewProvider {
    static var previews: some View {
        NetworkWidget()
            .frame(width: 200, height: 100)
            .background(Color.black)
    }
}
