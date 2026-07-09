import SwiftUI

/// Shared button style for the media popup's transport and toggle controls.
///
/// Provides consistent, native-feeling feedback: a circular hover highlight, a
/// subtle grow on hover, and a spring press-in. Toggle controls (shuffle,
/// repeat, favorite) pass `isActive` + `activeColor` to tint when engaged.
struct MediaControlButtonStyle: ButtonStyle {
    /// Diameter of the circular hit area / hover highlight.
    var size: CGFloat = 34
    /// Whether this control is in its "on" state (toggles only).
    var isActive: Bool = false
    /// Tint applied when `isActive`.
    var activeColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        MediaControlButton(
            configuration: configuration,
            size: size,
            isActive: isActive,
            activeColor: activeColor
        )
    }

    private struct MediaControlButton: View {
        let configuration: Configuration
        let size: CGFloat
        let isActive: Bool
        let activeColor: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(.white.opacity(hovering ? 0.12 : 0))
                )
                .foregroundStyle(
                    isActive
                        ? activeColor
                        : Color.white.opacity(hovering ? 1.0 : 0.85)
                )
                .scaleEffect(
                    configuration.isPressed ? 0.88 : (hovering ? 1.06 : 1.0)
                )
                .animation(
                    .spring(response: 0.25, dampingFraction: 0.6),
                    value: configuration.isPressed
                )
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
