import SwiftUI

/// Shared visual language for the Wi‑Fi widget — the same rounded "island"
/// card language as the AI Agent Usage widget (`AgentUsageStyle`), reused here
/// rather than reinventing spacing/fill tokens.
enum NetworkStyle {
    static let outerPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 10
    static let cardSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 8

    static let cardFill = Color.white.opacity(0.06)
    static let subtleCardFill = Color.white.opacity(0.04)
    static let rowHoverFill = Color.white.opacity(0.09)

    /// Popup width — wide enough for long SSIDs to truncate gracefully
    /// without the popup itself needing to grow.
    static let popupWidth: CGFloat = 320
    /// Caps how tall the "Other Networks" list can get before it scrolls
    /// internally, per the "sensible maximum height" requirement.
    static let networkListMaxHeight: CGFloat = 220
    /// Number of rows shown before "Show More Networks" is offered.
    static let collapsedNetworkRowCount = 4
}

extension View {
    /// Wraps content in a rounded "island" card.
    func networkCard(fill: Color = NetworkStyle.cardFill, cornerRadius: CGFloat = NetworkStyle.cardCornerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
    }
}

/// A small 4-bar Wi‑Fi signal glyph (like the native macOS menu), filled up to
/// `strength` (0...4). Used instead of `Image(systemName: "wifi")`, whose
/// fixed 3-arc shape can't represent "no connection" vs "weak" distinctly at
/// a glance in a dense list of rows.
struct WifiSignalIcon: View {
    var strength: Int
    var isOff: Bool = false
    var size: CGFloat = 14
    var activeColor: Color = .white
    var inactiveColor: Color = .white.opacity(0.25)

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.09) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: size * 0.16, height: barHeight(for: index))
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
        .opacity(isOff ? 0.4 : 1)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let step = size / 4
        return step * CGFloat(index + 1)
    }

    private func barColor(for index: Int) -> Color {
        isOff ? inactiveColor : (index < strength ? activeColor : inactiveColor)
    }
}

/// Signal-quality bar used in the Network Details view — a wider, labeled
/// version of the same idea used for the "Excellent/Good/Weak" summary.
struct SignalQualityBar: View {
    var strength: Int // 0...4
    var color: Color = .green

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < strength ? color : Color.white.opacity(0.15))
                    .frame(height: 6)
            }
        }
    }

    var label: String {
        switch strength {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Fair"
        case 1: return "Weak"
        default: return "No Signal"
        }
    }
}
