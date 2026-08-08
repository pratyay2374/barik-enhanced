import SwiftUI

/// Shared visual language for the unified widget: grouped, rounded "island"
/// sections with consistent edge insets, instead of a flat list separated by
/// hairline dividers.
enum AgentUsageStyle {
    static let outerPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 10

    static let cardFill = Color.white.opacity(0.06)
    static let subtleCardFill = Color.white.opacity(0.04)
}

extension View {
    /// Wraps content in a rounded "island" card — the shared replacement for
    /// hairline `Divider()` section separators throughout this widget.
    func agentUsageCard(fill: Color = AgentUsageStyle.cardFill, cornerRadius: CGFloat = AgentUsageStyle.cardCornerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
    }
}

/// Subtle press feedback (slight scale + dim) for the card-style buttons
/// throughout this widget — `.buttonStyle(.plain)` alone gives no tactile
/// response on click.
struct AgentCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AgentCardButtonStyle {
    static var agentCard: AgentCardButtonStyle { AgentCardButtonStyle() }
}

/// A small ring with the percentage centered inside it — richer than bare
/// text wherever a compact "at a glance" number is shown (currently the
/// overview rows).
struct UsageRing: View {
    let percentage: Double
    let color: Color
    var size: CGFloat = 26
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(percentage, 1.0)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: percentage)
            Text("\(Int(min(percentage, 1.0) * 100))")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}
