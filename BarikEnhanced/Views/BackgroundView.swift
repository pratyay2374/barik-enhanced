import SwiftUI

struct BackgroundView: View {
    @ObservedObject var configManager = ConfigManager.shared

    private func spacer(_ geometry: GeometryProxy) -> some View {
        let theme: ColorScheme? = {
            switch configManager.config.rootToml.theme {
            case "dark": return .dark
            case "light": return .light
            default: return nil
            }
        }()

        let height = configManager.config.experimental.background.resolveHeight()

        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: height ?? geometry.size.height)
            .preferredColorScheme(theme)
    }

    var body: some View {
        let bgConfig = configManager.config.experimental.background
        if bgConfig.displayed {
            GeometryReader { geometry in
                if bgConfig.blurRadius != nil || bgConfig.opacity != nil || bgConfig.color != nil {
                    spacer(geometry)
                        .background(
                            CustomBlurView(
                                radius: bgConfig.blurRadius ?? 0,
                                opacity: bgConfig.opacity ?? (bgConfig.black ? 1.0 : 0.0),
                                color: NSColor(hex: bgConfig.color) ?? (bgConfig.black ? .black : .clear)
                            )
                        )
                        .id("customBlur")
                } else if bgConfig.black {
                    spacer(geometry)
                        .background(.black)
                        .id("black")
                } else {
                    spacer(geometry)
                        .background(bgConfig.blur)
                        .id("blur")
                }
            }
        }
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard let hex = hex else { return nil }
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: CGFloat
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
