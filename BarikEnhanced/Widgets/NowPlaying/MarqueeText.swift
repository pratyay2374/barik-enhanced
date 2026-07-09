import SwiftUI

/// A single-line text view that scrolls its content in a continuous, one-directional
/// loop when it's wider than the space it's given.
///
/// Two copies of the text are laid out with a gap between them, and the whole strip
/// is offset by `-(elapsed × speed) mod (text + gap)` every frame via a
/// `TimelineView` clock. Because the offset is derived from time (not a repeating
/// state animation), the wrap from one copy to the next is perfectly seamless — no
/// reverse, no snap, no flicker — and it starts smoothly from rest at offset 0.
///
/// - In `scrollOnHoverOnly` mode (menu bar) it loops only while hovered; otherwise
///   (popup) it loops whenever the text overflows.
/// - When the text fits, it renders as a plain left-aligned `Text`.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    /// Only scroll while hovered (used in the menu bar).
    var scrollOnHoverOnly: Bool = false
    /// Optional external scroll trigger. When non-nil it overrides the internal
    /// hover state — lets a parent drive several marquees together (e.g. scroll
    /// title + artist as one when the menu-bar widget is hovered).
    var external: Bool? = nil
    /// Points-per-second scroll speed.
    var speed: Double = 30
    /// Gap between the end of the text and its repeated copy in the loop.
    var loopGap: CGFloat = 40
    /// Width of the edge fade.
    var fade: CGFloat = 12

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var hovering = false
    /// The instant scrolling last began; the offset is measured from here so the
    /// loop always starts at 0 (no jump) when hover begins.
    @State private var scrollStart = Date()

    private var isOverflowing: Bool { textWidth - containerWidth > 1 }
    private var shouldScroll: Bool {
        guard isOverflowing else { return false }
        if let external { return external }
        return scrollOnHoverOnly ? hovering : true
    }

    private func styledText() -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()  // keep full intrinsic width so we can scroll it
    }

    /// The first copy, carrying the width measurement. Rendered in both the
    /// overflowing and fitting branches, so `textWidth` is always up to date.
    private var measuredText: some View {
        styledText()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, w in textWidth = w }
                }
            )
    }

    var body: some View {
        // The container width must come from the *offered* space, independent of the
        // text's own width — a `GeometryReader` root reports exactly that.
        GeometryReader { geo in
            // The clock is paused when not scrolling, so there's zero per-frame work
            // at rest; while hovered it drives a smooth, seamless loop.
            TimelineView(.animation(paused: !shouldScroll)) { timeline in
                Group {
                    if isOverflowing {
                        HStack(spacing: loopGap) {
                            measuredText
                            styledText()  // seamless-loop copy
                        }
                        .offset(x: scrollOffset(at: timeline.date))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                        .clipped()
                        .mask(fadeMask)
                    } else {
                        measuredText
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                            .clipped()
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
            // Reset the time origin each time scrolling begins so it starts at 0.
            .onChange(of: shouldScroll) { _, nowScrolling in
                if nowScrolling { scrollStart = Date() }
            }
        }
    }

    /// Offset for the given frame time: 0 at rest, otherwise a continuous leftward
    /// sweep wrapped to one `(text + gap)` period so the second copy lands exactly
    /// where the first began.
    private func scrollOffset(at date: Date) -> CGFloat {
        guard shouldScroll else { return 0 }
        let period = textWidth + loopGap
        guard period > 0 else { return 0 }
        let traveled = CGFloat(max(0, date.timeIntervalSince(scrollStart)) * speed)
        return -traveled.truncatingRemainder(dividingBy: period)
    }

    /// Softens the clipped edges. The leading edge only fades while scrolling, so
    /// idle (truncated) text stays readable from its first glyph.
    @ViewBuilder
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: shouldScroll ? fade : 0)
            Rectangle().fill(.black)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: fade)
        }
    }
}
