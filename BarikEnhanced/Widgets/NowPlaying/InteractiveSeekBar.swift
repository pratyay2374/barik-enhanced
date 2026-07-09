import SwiftUI

/// Formats a time interval in seconds as `M:SS` (or `H:MM:SS` past an hour).
func formatMediaTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// A playback progress bar that interpolates position smoothly at display
/// refresh rate (so it never jumps between polls) and — when the player
/// supports it — lets the user click or drag to seek.
///
/// While playing, the displayed position is `position + (now - fetchedAt)`,
/// re-anchored each time a fresh poll updates `position`/`fetchedAt`. When
/// paused, the timeline is paused too, so there's no idle rendering cost.
struct InteractiveSeekBar: View {
    /// Last sampled position (seconds).
    let position: Double
    let duration: Double
    let isPlaying: Bool
    /// Instant `position` was sampled — the interpolation anchor.
    let fetchedAt: Date
    let accent: Color
    /// Whether click/drag seeking is available (Apple Music). If false, the bar
    /// is read-only.
    let canSeek: Bool
    /// Called with the target position (seconds) when a seek gesture ends.
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var hovering = false

    private let trackHeight: CGFloat = 5

    var body: some View {
        // ~10fps is plenty for a bar that advances ~1px/sec, and far cheaper
        // than the display's full (up to 120Hz) refresh. Paused entirely when
        // not playing or while dragging (the drag drives its own updates).
        TimelineView(
            .animation(minimumInterval: 0.1, paused: !isPlaying || dragFraction != nil)
        ) { context in
            let pos = displayPosition(at: context.date)
            let fraction = duration > 0 ? min(1, max(0, pos / duration)) : 0

            VStack(spacing: 6) {
                track(fraction: fraction)
                HStack {
                    Text(formatMediaTime(pos))
                    Spacer()
                    Text(formatMediaTime(duration))
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .monospacedDigit()
            }
        }
    }

    // MARK: - Track

    private func track(fraction: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumb: CGFloat = (hovering || dragFraction != nil) ? 14 : 11
            let center = w * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(accent)
                    .frame(width: max(0, min(w, center)), height: trackHeight)

                if canSeek {
                    Circle()
                        .fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: min(max(center - thumb / 2, -thumb / 2), w - thumb / 2))
                }
            }
            .frame(height: max(thumb, trackHeight))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(canSeek ? seekGesture(width: w) : nil)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: dragFraction != nil)
        }
        .frame(height: 16)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                dragFraction = min(1, max(0, value.location.x / width))
            }
            .onEnded { value in
                guard width > 0 else { return }
                let f = min(1, max(0, value.location.x / width))
                dragFraction = nil
                onSeek(f * duration)
            }
    }

    // MARK: - Interpolation

    private func displayPosition(at now: Date) -> Double {
        if let dragFraction { return dragFraction * duration }
        guard duration > 0 else { return position }
        if isPlaying {
            let elapsed = now.timeIntervalSince(fetchedAt)
            return min(duration, position + max(0, elapsed))
        }
        return position
    }
}
