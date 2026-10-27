import SwiftUI

struct BackgroundView: View {
    @ObservedObject var configManager = ConfigManager.shared
    let screen: NSScreen?

    private var wallpaper: NSImage? {
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if configManager.config.experimental.background.displayed {
            GeometryReader { geometry in
                backgroundColor(geometry)
            }
        }
    }

    @ViewBuilder
    private func backgroundColor(_ geometry: GeometryProxy) -> some View {
        let height = configManager.config.experimental.background.resolveHeight()
            ?? geometry.size.height
        let background = configManager.config.experimental.background
        let theme: ColorScheme? = {
            switch configManager.config.rootToml.theme {
            case "dark": return .dark
            case "light": return .light
            default: return nil
            }
        }()

        Group {
            if background.blurRadius != nil || background.opacity != nil || background.color != nil {
                Color.clear.background(
                    CustomBlurView(
                        radius: background.blurRadius ?? 0,
                        opacity: background.opacity ?? (background.black ? 1.0 : 0.0),
                        color: NSColor(hex: background.color) ?? (background.black ? .black : .clear)
                    )
                )
            } else if background.black {
                Color.black
            } else if let wallpaper {
                // A Material only tints the desktop; this is a real Gaussian
                // blur of the wallpaper, so none of the original colours are
                // replaced by gray.
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: background.wallpaperBlurRadius)
                    .clipped()
            } else {
                Color.clear
                    .background(background.blur)
            }
        }
        .frame(width: geometry.size.width, height: height, alignment: .top)
        .preferredColorScheme(theme)
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
