import SwiftUI

/// The Now Playing popup — a compact "mini media player" with album art,
/// marquee metadata, an interactive seek bar, transport + toggle controls, a
/// compact volume slider, and subtle album-art-derived theming.
///
/// A single unified layout (the previous vertical/horizontal variant switch was
/// removed). Playback state, progress, and accent color come from
/// `NowPlayingManager`; heavy work (fast polling, interpolation) is gated to
/// while this view is on screen via `setPopupVisible`.
struct NowPlayingPopup: View {
    @ObservedObject private var playingManager = NowPlayingManager.shared
    @ObservedObject private var audioManager = AudioVisualManager.shared

    @State private var pulse = false

    private let width: CGFloat = 300
    private let artSize: CGFloat = 180

    var body: some View {
        Group {
            if let song = playingManager.nowPlaying {
                player(for: song)
            } else {
                nothingPlaying
            }
        }
        .frame(width: width)
        .foregroundStyle(.white)
        .onAppear { playingManager.setPopupVisible(true) }
        .onDisappear { playingManager.setPopupVisible(false) }
        .onKeyPress(.escape) {
            NotificationCenter.default.post(name: .willHideWindow, object: nil)
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    private var accent: Color { playingManager.accentColor }

    // MARK: - Player

    private func player(for song: NowPlayingSong) -> some View {
        VStack(spacing: 16) {
            artwork(for: song)

            metadata(for: song)
                .opacity(playingManager.isLoading ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.2), value: playingManager.isLoading)

            InteractiveSeekBar(
                position: song.position ?? 0,
                duration: song.duration ?? 0,
                isPlaying: song.state == .playing,
                fetchedAt: song.fetchedAt,
                accent: accent,
                canSeek: song.canSeek,
                onSeek: { playingManager.seek(to: $0) }
            )

            transportControls(for: song)

            secondaryControls(for: song)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(accentGlowBackground)
    }

    // MARK: - Artwork

    private func artwork(for song: NowPlayingSong) -> some View {
        ZStack {
            // Album-art-derived glow. Kept OUTSIDE the pulse scaleEffect so the
            // expensive blur isn't re-composited every animation frame.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(accent)
                .frame(width: artSize, height: artSize)
                .blur(radius: 38)
                .opacity(0.35)

            // The art card (placeholder + image + loading) — only this pulses.
            ZStack {
                // Placeholder sits behind the (transparent-until-loaded) image.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.white.opacity(0.25))
                    )
                    .frame(width: artSize, height: artSize)

                RotateAnimatedCachedImage(
                    url: song.albumArtURL,
                    data: song.albumArtData,
                    targetSize: CGSize(width: 400, height: 400)
                ) { image in
                    image
                        .aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(width: artSize, height: artSize)

                // Loading spinner during track changes.
                if playingManager.isLoading {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.35))
                        .frame(width: artSize, height: artSize)
                        .overlay(ProgressView().controlSize(.small).tint(.white))
                }
            }
            .scaleEffect(artScale(for: song))
            .brightness(song.state == .paused ? -0.06 : 0)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { playingManager.openApp() }
        .help("Open \(song.appName)")
        .onAppear { startPulse(for: song) }
        .onChange(of: song.state) { _, _ in startPulse(for: song) }
    }

    private func artScale(for song: NowPlayingSong) -> CGFloat {
        if song.state == .paused { return 0.94 }
        return pulse ? 1.015 : 1.0
    }

    private func startPulse(for song: NowPlayingSong) {
        pulse = false
        guard song.state == .playing else { return }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    // MARK: - Metadata

    private func metadata(for song: NowPlayingSong) -> some View {
        VStack(spacing: 3) {
            MarqueeText(
                text: song.title,
                font: .system(size: 16, weight: .semibold, design: .rounded),
                color: .white
            )
            .frame(height: 21)
            .onTapGesture { playingManager.openApp() }

            MarqueeText(
                text: song.artist,
                font: .system(size: 13, weight: .regular, design: .rounded),
                color: .white.opacity(0.6)
            )
            .frame(height: 17)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transport

    private func transportControls(for song: NowPlayingSong) -> some View {
        HStack(spacing: 24) {
            Button(action: { playingManager.previousTrack() }) {
                Image(systemName: "backward.fill").font(.system(size: 18))
            }
            .buttonStyle(MediaControlButtonStyle(size: 42))
            .accessibilityLabel("Previous track")

            Button(action: { playingManager.togglePlayPause() }) {
                Image(systemName: song.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 26))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(MediaControlButtonStyle(size: 54))
            .accessibilityLabel(song.state == .paused ? "Play" : "Pause")

            Button(action: { playingManager.nextTrack() }) {
                Image(systemName: "forward.fill").font(.system(size: 18))
            }
            .buttonStyle(MediaControlButtonStyle(size: 42))
            .accessibilityLabel("Next track")
        }
    }

    // MARK: - Secondary controls (auto-hide when unsupported)

    private func secondaryControls(for song: NowPlayingSong) -> some View {
        HStack(spacing: 14) {
            if song.canShuffle {
                Button(action: { playingManager.toggleShuffle() }) {
                    Image(systemName: "shuffle").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(MediaControlButtonStyle(
                    size: 30,
                    isActive: song.shuffleEnabled ?? false,
                    activeColor: accent))
                .accessibilityLabel("Shuffle")
            }

            if song.canRepeat {
                Button(action: { playingManager.cycleRepeat() }) {
                    Image(systemName: repeatIcon(for: song))
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(MediaControlButtonStyle(
                    size: 30,
                    isActive: (song.repeatMode ?? .off) != .off,
                    activeColor: accent))
                .accessibilityLabel("Repeat")
            }

            if song.canFavorite {
                Button(action: { playingManager.toggleFavorite() }) {
                    Image(systemName: (song.isFavorite ?? false) ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(MediaControlButtonStyle(
                    size: 30,
                    isActive: song.isFavorite ?? false,
                    activeColor: .pink))
                .accessibilityLabel("Favorite")
            }

            Spacer(minLength: 8)

            volumeControl
        }
    }

    private func repeatIcon(for song: NowPlayingSong) -> String {
        (song.repeatMode ?? .off) == .one ? "repeat.1" : "repeat"
    }

    // MARK: - Compact volume

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Slider(
                value: Binding(
                    get: { audioManager.volumeLevel },
                    set: { audioManager.setVolume(level: $0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 78)
            .tint(.white.opacity(0.8))
        }
    }

    // MARK: - Background

    private var accentGlowBackground: some View {
        LinearGradient(
            colors: [accent.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .allowsHitTesting(false)
    }

    // MARK: - Empty state

    private var nothingPlaying: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Nothing Playing")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            Text("Play something in Music or Spotify")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Preview

struct NowPlayingPopup_Previews: PreviewProvider {
    static var previews: some View {
        NowPlayingPopup()
            .background(Color.black)
            .previewLayout(.sizeThatFits)
    }
}
