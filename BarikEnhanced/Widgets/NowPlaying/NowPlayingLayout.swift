import AppKit
import SwiftUI

/// Fonts used to measure the song text off the layout pass. These **must** match
/// the fonts `SongTextView` actually renders (`NowPlayingWidget.swift`); a weight
/// mismatch under-measures and produces intermittent one-glyph truncation.
enum NPMetrics {
    /// `.system(size: 12, weight: .medium)` — title in the two-line (tall) layout.
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// `.system(size: 10)` — artist in the two-line (tall) layout.
    static let artistFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    /// `.system(size: 12)` — single "Artist — Title" line used on short bars.
    static let combinedFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// Rendered width of `string` in `font`, rounded up with a small pad so
    /// Core Text advance widths never fall a sub-pixel short of SwiftUI's `Text`
    /// bounds (which would clip the last glyph).
    static func textWidth(_ string: String, _ font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

/// How much of the song the widget shows, chosen by the available width.
/// `full` = artwork + title + artist · `compact` = artwork + title ·
/// `ultra` = artwork only.
enum NPMode: Equatable {
    case full, compact, ultra
}

/// Pure width math for the Now Playing text column. No timers, no observable
/// state — every value is derived from the song strings and the notch/space
/// budget, so it recomputes only when those actually change.
enum NPLayout {
    /// Never let the text column go narrower than this (fits a short title stub).
    static let minTextWidth: CGFloat = 44

    // Fixed columns that flank the text inside the widget, subtracted from the
    // notch-safe boundary to find the room left for text.
    private static let artworkColumn: CGFloat = 20   // AlbumArtView 20×20
    private static let interSpacing: CGFloat = 8      // HStack spacing
    private static let safetyGap: CGFloat = 12        // never kiss the notch

    // Mode thresholds, measured against the text budget (room left for text).
    private static let fullMinBudget: CGFloat = 84    // enough for a legible title+artist
    private static let compactMinBudget: CGFloat = 40 // enough for a readable title stub
    private static let modeBand: CGFloat = 12         // hysteresis dead band

    /// Next display mode for a given text budget, with Schmitt-trigger hysteresis:
    /// entering a roomier mode requires clearing the threshold by `modeBand`, while
    /// dropping happens at the bare threshold. Because it reads `current`, an
    /// unchanged budget never re-toggles — no flicker at the boundary.
    static func nextMode(current: NPMode, budget: CGFloat) -> NPMode {
        switch current {
        case .full:
            if budget < compactMinBudget { return .ultra }
            if budget < fullMinBudget { return .compact }
            return .full
        case .compact:
            if budget < compactMinBudget { return .ultra }
            if budget >= fullMinBudget + modeBand { return .full }
            return .compact
        case .ultra:
            if budget >= fullMinBudget + modeBand { return .full }
            if budget >= compactMinBudget + modeBand { return .compact }
            return .ultra
        }
    }

    /// Natural (unclamped) width the text wants for `mode`, picking the fonts that
    /// match the current bar height's layout branch.
    static func idealTextWidth(
        title: String, artist: String, foregroundHeight: CGFloat, mode: NPMode
    ) -> CGFloat {
        if mode == .ultra { return 0 }
        if foregroundHeight >= 30 {
            let titleW = NPMetrics.textWidth(title, NPMetrics.titleFont)
            if mode == .compact { return titleW }
            return max(titleW, NPMetrics.textWidth(artist, NPMetrics.artistFont))
        } else {
            let text = (mode == .compact || artist.isEmpty) ? title : "\(artist) — \(title)"
            return NPMetrics.textWidth(text, NPMetrics.combinedFont)
        }
    }

    /// Horizontal points available to the text before the widget would hit the
    /// notch or the reserved status area. `.greatestFiniteMagnitude` when the
    /// screen isn't resolved yet (caller then falls back to the content/max clamp).
    ///
    /// Section-aware, because barik's bar splits at the first spacer/divider:
    /// - **Leading** widgets grow rightward from a left edge that is pinned to the
    ///   bar's leading padding, so `widgetMinX` is the invariant anchor and the
    ///   boundary is the notch's left edge (notched) or the reserved status area.
    /// - **Trailing** widgets are pinned to the right and grow leftward, so
    ///   `widgetMaxX` is the invariant anchor (its right-hand neighbours are
    ///   fixed-width) and the boundary is the notch's right edge (notched) or the
    ///   bar's leading padding.
    ///
    /// Each branch anchors on the edge that does **not** move with this widget's own
    /// width, so there is no layout feedback loop.
    static func availableTextBudget(
        widgetMinX: CGFloat,
        widgetMaxX: CGFloat,
        isTrailing: Bool,
        screen: NSScreen?,
        foregroundHeight: CGFloat
    ) -> CGFloat {
        guard let screen else { return .greatestFiniteMagnitude }
        // Frame not resolved yet (.zero): fall back to the content/max clamp so the
        // widget doesn't momentarily collapse to ultra on first paint.
        guard widgetMaxX > widgetMinX else { return .greatestFiniteMagnitude }
        let capsulePad: CGFloat = foregroundHeight >= 45 ? 24 : (foregroundHeight >= 38 ? 16 : 0)
        let fixed = artworkColumn + interSpacing + capsulePad + safetyGap

        if isTrailing {
            let leftBoundary = screen.notchTrailingInset
                ?? ConfigManager.shared.config.experimental.foreground.horizontalPadding
            return widgetMaxX - leftBoundary - fixed
        } else {
            let rightBoundary = screen.notchLeadingInset
                ?? (screen.frame.width - MenuBarMetrics.trailingReservation(for: screen))
            return rightBoundary - widgetMinX - fixed
        }
    }

    /// Final width for the text column: sized to content, clamped to
    /// `[minWidth, maxWidth]`, then further clamped by the available budget and
    /// floored at `minWidth` so it never renders zero-width.
    static func columnWidth(
        title: String,
        artist: String,
        foregroundHeight: CGFloat,
        mode: NPMode,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        budget: CGFloat
    ) -> CGFloat {
        let ideal = idealTextWidth(
            title: title, artist: artist, foregroundHeight: foregroundHeight, mode: mode
        )
        let byContent = min(max(ideal, minWidth), maxWidth)
        return max(minWidth, min(byContent, budget))
    }
}
