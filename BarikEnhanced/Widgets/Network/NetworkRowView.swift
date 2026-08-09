import SwiftUI

/// A single row in the "Other Networks" list — signal icon, truncating SSID,
/// lock glyph when secured, and a trailing status (checkmark when currently
/// joining/joined, chevron affordance otherwise via hover highlight).
struct NetworkRowView: View {
    let network: WiFiNetwork
    /// True while this specific row's join attempt is in flight.
    var isConnecting: Bool = false
    var onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                WifiSignalIcon(strength: network.signalBars, size: 15)

                Text(network.ssid)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    if network.isSecured {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, NetworkStyle.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: NetworkStyle.rowCornerRadius, style: .continuous)
                    .fill(isHovering ? NetworkStyle.rowHoverFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .onHover { hovering in
            isHovering = hovering
        }
        .pointingHandOnHover()
        .accessibilityLabel("\(network.ssid), \(network.isSecured ? "secured" : "open") network")
    }
}
