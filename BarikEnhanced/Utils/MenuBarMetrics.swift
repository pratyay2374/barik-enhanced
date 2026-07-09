import AppKit
import Combine

/// Reserves trailing space in Barik Enhanced's menu bar so its widgets don't render
/// where macOS draws its native status icons (WiFi, battery, clock, Control
/// Center, etc.).
///
/// History: previously this measured the actual native-status-area width by
/// placing a probe NSStatusItem at the left edge and reading its frame. That
/// turned out to react to third-party menu-bar utilities (Hidden Bar,
/// Bartender, etc.) — every time the user toggled those, Barik Enhanced's trailing
/// widgets shifted around because the underlying width changed. To avoid that
/// jitter, we now reserve a fixed conservative width that comfortably clears
/// a typical macOS status area.
final class MenuBarMetrics: ObservableObject {
    static let shared = MenuBarMetrics()

    /// Trailing reservation in points. Defaults to 0 so the bar runs
    /// edge-to-edge; users who want a cushion can set
    /// `experimental.foreground.horizontalPadding` in their config —
    /// Barik Enhanced uses `max(horizontalPadding, systemStatusAreaWidth)`
    /// for the trailing pad.
    @Published var systemStatusAreaWidth: CGFloat = 0

    private init() {}

    /// Kept for API compatibility with AppDelegate's lifecycle hooks; the
    /// reservation is static and does not need to be re-detected on wake or
    /// session changes.
    func startDetecting() {}

    /// Kept for API compatibility. No-op — see `startDetecting`.
    func restartDetection() {}

    /// Trailing reservation in points that clears macOS's native status icons.
    ///
    /// Narrow screens (< 1500 pt wide) get 220 pt of clearance; wide screens use
    /// only `horizontal-padding` so the bar stays close to the right edge. A user
    /// `experimental.foreground.system-status-reservation` overrides the heuristic.
    ///
    /// Pass the screen a widget lives on to reserve for *that* display; pass `nil`
    /// (as the bar layout does) to key the heuristic off the narrowest screen.
    static func trailingReservation(for screen: NSScreen? = nil) -> CGFloat {
        let foreground = ConfigManager.shared.config.experimental.foreground
        let hp = foreground.horizontalPadding
        if let userReservation = foreground.systemStatusReservation {
            return max(hp, userReservation)
        }
        let width = screen?.frame.width
            ?? (NSScreen.screens.map { $0.frame.width }.min() ?? .infinity)
        if width < 1500 {
            return max(hp, 220)
        }
        return hp
    }
}
