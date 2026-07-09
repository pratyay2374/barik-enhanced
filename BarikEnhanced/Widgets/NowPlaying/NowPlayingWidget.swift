import AppKit
import SwiftUI

// MARK: - Now Playing Widget

struct NowPlayingWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject var playingManager = NowPlayingManager.shared

    @State private var widgetFrame: CGRect = .zero
    /// The screen this widget's panel lives on, resolved via `ScreenReader`.
    /// Drives notch-aware width so the item never slides under the notch.
    @State private var hostScreen: NSScreen?

    var config: ConfigData { configProvider.config }

    /// Upper bound of the song text column. The column sizes to its content and
    /// is clamped to this max (and to the notch-safe budget), so short titles stay
    /// narrow and long titles marquee-scroll on hover instead of growing the bar.
    /// Configurable via `widgets.default.nowplaying.max-width` (default 110).
    private var maxTextWidth: CGFloat {
        if let d = config["max-width"]?.doubleValue { return CGFloat(d) }
        return 85
    }

    /// Presentation override. `auto` keeps the adaptive full/compact/ultra behavior;
    /// the rest force a fixed presentation (width clamping still applies).
    /// `widgets.default.nowplaying.display-mode`.
    private var displayMode: String { config["display-mode"]?.stringValue ?? "auto" }

    /// Fixed mode forced by `display-mode`, or nil for `auto`/`icon-only`.
    private var forcedMode: NPMode? {
        switch displayMode {
        case "artwork-only": return .ultra
        case "title-only": return .compact
        case "title-artist": return .full
        default: return nil
        }
    }

    /// `display-mode = "icon-only"` renders just a music glyph, no artwork or text.
    private var iconOnly: Bool { displayMode == "icon-only" }

    /// Whether this widget sits in the bar's trailing (right-pinned) section.
    /// Mirrors `MenuBarView.splitItems`: everything after the first spacer/divider
    /// is trailing. Trailing widgets grow leftward, so the width budget anchors on
    /// the right edge instead of the left.
    private var isTrailing: Bool {
        var afterSplit = false
        for item in configManager.config.rootToml.widgets.displayed {
            if item.id == "default.nowplaying" { return afterSplit }
            if !afterSplit, item.id == "spacer" || item.id == "divider" {
                afterSplit = true
            }
        }
        return afterSplit
    }

    @ObservedObject private var configManager = ConfigManager.shared

    var body: some View {
        ZStack {
            if let song = playingManager.nowPlaying {
                NowPlayingContent(
                    song: song,
                    maxTextWidth: maxTextWidth,
                    widgetMinX: widgetFrame.minX,
                    widgetMaxX: widgetFrame.maxX,
                    isTrailing: isTrailing,
                    hostScreen: hostScreen,
                    forcedMode: forcedMode,
                    iconOnly: iconOnly
                )
                // Solid hit area so a tap anywhere on the item opens the mini-player,
                // not just on the opaque glyphs (matters in artwork-only mode). Native
                // `.help` tooltips don't display in barik's LSUIElement/non-activating
                // panel, so full metadata is surfaced via this click-to-open popup and
                // the hover marquee instead.
                .contentShape(Rectangle())
                .onTapGesture {
                    MenuBarPopup.show(rect: widgetFrame, id: "nowplaying") {
                        NowPlayingPopup()
                    }
                }
                .transition(.blurReplace)
            } else {
                // Nothing playing: fade to a minimal, inert placeholder at a stable
                // footprint so the item doesn't collapse and shift the bar.
                NowPlayingEmptyView()
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.25), value: playingManager.nowPlaying == nil)
        .animation(.smooth(duration: 0.2), value: playingManager.nowPlaying?.id)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        widgetFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                        widgetFrame = newFrame
                    }
            }
        )
        .background(ScreenReader(screen: $hostScreen))
    }
}

// MARK: - Now Playing Content

/// A view that composes the album art and song text into a capsule-shaped content view.
struct NowPlayingContent: View {
    let song: NowPlayingSong
    let maxTextWidth: CGFloat
    /// The widget's left edge, in window-local coordinates (== distance from the
    /// screen's leading edge, since each panel sits at its screen origin).
    let widgetMinX: CGFloat
    /// The widget's right edge, in the same coordinate space as `widgetMinX`.
    let widgetMaxX: CGFloat
    /// Whether this widget is in the bar's trailing section (grows leftward).
    let isTrailing: Bool
    /// The screen hosting this widget, for notch-aware sizing.
    let hostScreen: NSScreen?
    /// Fixed presentation forced by `display-mode`; nil = adaptive.
    let forcedMode: NPMode?
    /// Render a music glyph only (no artwork/text) — `display-mode = "icon-only"`.
    let iconOnly: Bool
    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    /// Hover state so the title and artist marquee-scroll together only while the
    /// pointer is over the widget.
    @State private var hovering = false
    /// Adaptive mode chosen by available width (used only when not overridden).
    @State private var mode: NPMode = .full

    /// The mode actually rendered: the `display-mode` override if set, else adaptive.
    private var effectiveMode: NPMode { forcedMode ?? mode }

    /// Horizontal points available to the text before hitting the notch / status
    /// area. Drives both the column width and the display mode.
    private var textBudget: CGFloat {
        NPLayout.availableTextBudget(
            widgetMinX: widgetMinX,
            widgetMaxX: widgetMaxX,
            isTrailing: isTrailing,
            screen: hostScreen,
            foregroundHeight: foregroundHeight
        )
    }

    /// Width cap for the text column: `min(content, notch-safe budget)`, floored at
    /// `minTextWidth`. Applied downstream as a `maxWidth`, so the column sizes to the
    /// song for short titles, caps here for long ones, and yields further (then
    /// marquees) when the trailing group is crowded.
    private var columnWidth: CGFloat {
        NPLayout.columnWidth(
            title: song.title,
            artist: song.artist,
            foregroundHeight: foregroundHeight,
            mode: effectiveMode,
            minWidth: NPLayout.minTextWidth,
            maxWidth: maxTextWidth,
            budget: textBudget
        )
    }

    var body: some View {
        Group {
            if foregroundHeight < 38 {
                content
            } else {
                content
                    .padding(.horizontal, foregroundHeight < 45 ? 8 : 12)
                    .frame(height: foregroundHeight < 45 ? 30 : 38)
                    .background(configManager.config.experimental.foreground.widgetsBackground.blur)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.noActive, lineWidth: 1)
                    )
            }
        }
        .foregroundColor(.foreground)
        .onHover { hovering = $0 }
        // Scope animations to layout-affecting values so routine playback-position
        // ticks never animate; only genuine width/mode/track/color changes ease —
        // width, text crossfade, and artwork all share the same 0.25 beat.
        .animation(.smooth(duration: 0.25), value: columnWidth)
        .animation(.smooth(duration: 0.25), value: effectiveMode)
        .animation(.smooth(duration: 0.25), value: song.id)
        // Re-evaluate the adaptive mode when the budget changes (auto only).
        .onChange(of: textBudget, initial: true) { _, newBudget in
            guard forcedMode == nil else { return }
            mode = NPLayout.nextMode(current: mode, budget: newBudget)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if iconOnly {
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
            } else {
                HStack(spacing: effectiveMode == .ultra ? 0 : 8) {
                    AlbumArtView(song: song)
                    if effectiveMode != .ultra {
                        SongTextView(
                            song: song, width: columnWidth,
                            mode: effectiveMode, hovering: hovering
                        )
                        // New identity per track → SwiftUI cross-dissolves the text
                        // on song change (a fresh MarqueeText mounts at offset 0, so
                        // its `.none` reset can't fight the fade). Also covers the
                        // ultra in/out (now a fade rather than a slide).
                        .id(song.id)
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

// MARK: - Empty State

/// Shown when nothing is playing: a faded music-note glyph at the artwork's
/// footprint, wrapped in the same optional capsule chrome as the playing state so
/// the item stays visually consistent and keeps its place in the bar.
struct NowPlayingEmptyView: View {
    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    private var glyph: some View {
        Image(systemName: "music.note")
            .font(.system(size: 12))
            .foregroundColor(.foreground.opacity(0.4))
            .frame(width: 20, height: 20)
    }

    var body: some View {
        Group {
            if foregroundHeight < 38 {
                glyph
            } else {
                glyph
                    .padding(.horizontal, foregroundHeight < 45 ? 8 : 12)
                    .frame(height: foregroundHeight < 45 ? 30 : 38)
                    .background(configManager.config.experimental.foreground.widgetsBackground.blur)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.noActive.opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Album Art View

/// A view that displays the album art with a fade animation and a pause indicator if needed.
struct AlbumArtView: View {
    let song: NowPlayingSong

    var body: some View {
        ZStack {
            FadeAnimatedCachedImage(
                url: song.albumArtURL,
                data: song.albumArtData,
                targetSize: CGSize(width: 40, height: 40)
            )
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .scaleEffect(song.state == .paused ? 0.9 : 1)
            .brightness(song.state == .paused ? -0.3 : 0)

            if song.state == .paused {
                Image(systemName: "pause.fill")
                    .foregroundColor(.icon)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.1), value: song.state == .paused)
    }
}

// MARK: - Song Text View

/// A view that displays the song title and (in `full` mode) artist,
/// marquee-scrolling on hover within a content-adaptive column so long titles
/// don't stretch the menu bar. The artist is dropped wholesale in `compact` mode
/// — title always keeps priority over artist.
struct SongTextView: View {
    let song: NowPlayingSong
    /// Exact width of the text column, `min(content, notch-safe budget)`. Applied as
    /// a rigid frame so the text is hard-clipped at the widget's edge and can never
    /// draw under a neighbouring menu-bar item; overflow is revealed by the marquee.
    let width: CGFloat
    /// `full` shows title + artist; `compact` shows title only. (`ultra` never
    /// renders this view.)
    let mode: NPMode
    /// True while the pointer is over the widget; marquees scroll only then.
    let hovering: Bool
    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    var body: some View {
        Group {
            if foregroundHeight >= 30 {
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(
                        text: song.title,
                        font: .system(size: 12, weight: .medium),
                        color: .foreground,
                        scrollOnHoverOnly: true,
                        external: hovering
                    )
                    .frame(width: width, height: 15, alignment: .leading)

                    if mode == .full {
                        MarqueeText(
                            text: song.artist,
                            font: .system(size: 10),
                            color: .foreground.opacity(0.6),
                            scrollOnHoverOnly: true,
                            external: hovering
                        )
                        // Bound each line to `width` directly: a `.frame(width:)` on
                        // the VStack constrains the first child but not a second one
                        // carrying a `.transition`, so it must be applied per line.
                        .frame(width: width, height: 12, alignment: .leading)
                        // Artist fades/slides in and out as space allows, rather
                        // than truncating alongside the title.
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(width: width, alignment: .leading)
            } else {
                MarqueeText(
                    text: mode == .full ? (song.artist + " — " + song.title) : song.title,
                    font: .system(size: 12),
                    color: .foreground,
                    scrollOnHoverOnly: true,
                    external: hovering
                )
                .frame(width: width, alignment: .leading)
                .frame(height: 15)
            }
        }
    }
}

// MARK: - Preview

struct NowPlayingWidget_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            NowPlayingWidget()
        }
        .frame(width: 500, height: 100)
    }
}
