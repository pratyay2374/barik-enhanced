import SwiftUI

/// Compact "Network Details" screen (doc section 10) for the currently
/// connected network — reachable from the current-network row, hidden by
/// default so the primary popup stays small.
struct NetworkDetailsView: View {
    let ssid: String
    let signalBars: Int
    let securityLabel: String
    let ipAddress: String
    let frequencyLabel: String
    var onForget: () -> Void
    var onClose: () -> Void

    private var quality: SignalQualityBar { SignalQualityBar(strength: signalBars) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(ssid)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 8) {
                    quality
                        .frame(width: 44)
                    Text(quality.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(10)
            .networkCard(fill: NetworkStyle.subtleCardFill, cornerRadius: 10)

            VStack(spacing: 0) {
                detailRow(label: "Security", value: securityLabel)
                Divider().background(.white.opacity(0.08))
                detailRow(label: "IP Address", value: ipAddress)
                Divider().background(.white.opacity(0.08))
                detailRow(label: "Frequency", value: frequencyLabel)
            }
            .networkCard(fill: NetworkStyle.subtleCardFill, cornerRadius: 10)

            Button(action: onForget) {
                Text("Forget This Network")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(14)
        .networkCard()
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
