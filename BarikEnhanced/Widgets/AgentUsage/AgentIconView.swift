import SwiftUI

/// Renders a provider's brand icon when a real asset exists. Providers
/// without one (OpenCode, Cursor) get a monogram badge instead of a generic
/// SF Symbol — a plain "cursorarrow" glyph reads as a stray mouse pointer
/// sitting on the widget rather than a logo, so a colored letter badge is
/// both less ambiguous and more consistent with the two real brand marks.
struct AgentIconView: View {
    let descriptor: AgentProviderDescriptor
    var size: CGFloat = 16
    var monochrome: Bool = false

    var body: some View {
        Group {
            if let assetName = descriptor.iconAssetName {
                // Always tinted (never the asset's raw color) so the icon
                // reads as branded — e.g. Claude's mark shows in Claude
                // orange when active, not the artwork's plain black.
                Image(assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(monochrome ? AnyShapeStyle(.white) : AnyShapeStyle(descriptor.brandColor))
            } else if let letter = descriptor.monogramLetter {
                let tint = monochrome ? Color.white : descriptor.brandColor
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(tint.opacity(monochrome ? 0.18 : 0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28)
                            .strokeBorder(tint.opacity(monochrome ? 0.35 : 0.4), lineWidth: 1)
                    )
                    .overlay(
                        Text(letter)
                            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                    )
            } else {
                Image(systemName: descriptor.sfSymbolFallback)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(monochrome ? AnyShapeStyle(.white) : AnyShapeStyle(descriptor.brandColor))
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovered. Shared across the
    /// AgentUsage views (each old usage popup had its own private copy).
    func pointingHandOnHover() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
