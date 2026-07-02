import SwiftUI

/// Widget for the menu, displaying Wi‑Fi and Ethernet icons.
struct NetworkWidget: View {
    @ObservedObject private var viewModel = NetworkStatusViewModel.shared
    @State private var rect: CGRect = .zero

    var body: some View {
        HStack(spacing: 15) {
            if shouldShowWifi {
                wifiIcon
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

    /// Show the Wi-Fi icon only when Wi-Fi is the active interface, explicitly
    /// disabled, or has no connectivity — but NOT when it's merely "available
    /// but not in use" while Ethernet is the active connection.
    private var shouldShowWifi: Bool {
        switch viewModel.wifiState {
        case .notSupported:
            // No Wi-Fi hardware at all — hide
            return false
        case .disconnected:
            // Wi-Fi interface is available but not in use (e.g. Ethernet is
            // the active path). Only show if Ethernet is also not connected,
            // so the user still gets *something* clickable.
            return viewModel.ethernetState != .connected
                && viewModel.ethernetState != .connectedWithoutInternet
        default:
            // connected, connecting, connectedWithoutInternet, disabled — always show
            return true
        }
    }

    private var wifiIcon: some View {
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
