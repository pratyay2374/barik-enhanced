import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Playback State

/// Represents the current playback state.
enum PlaybackState: String {
    case playing, paused, stopped
}

/// Repeat mode for players that support it (Apple Music).
/// Raw values double as the AppleScript `song repeat` constants (`off`/`one`/`all`).
enum RepeatMode: String {
    case off, one, all
}

// MARK: - Now Playing Song Model

/// A model representing the currently playing song.
///
/// Fields that a control mutates optimistically (`state`, `position`,
/// `isFavorite`, `shuffleEnabled`, `repeatMode`) are `var`. `fetchedAt` anchors
/// smooth progress interpolation and is deliberately excluded from equality so
/// re-fetching an otherwise-identical song doesn't churn `@Published`.
struct NowPlayingSong: Equatable, Identifiable {
    var id: String { title + artist }
    let appName: String
    var state: PlaybackState
    let title: String
    let artist: String
    let albumArtURL: URL?
    /// Raw artwork bytes for apps that don't expose an artwork URL (e.g. Apple Music).
    var albumArtData: Data?
    var position: Double?
    let duration: Double?  // Duration in seconds
    var isFavorite: Bool?
    var shuffleEnabled: Bool?
    var repeatMode: RepeatMode?
    /// Wall-clock instant this snapshot's `position` was sampled — the anchor
    /// for interpolating a smooth playback position between polls.
    var fetchedAt: Date = Date()

    // MARK: Capabilities (drive which controls are shown)

    var isMusic: Bool { appName == MusicApp.music.rawValue }
    /// Seeking via `set player position` is reliable on Apple Music only.
    var canSeek: Bool { isMusic }
    /// `loved` is an Apple Music track property; Spotify has no equivalent.
    var canFavorite: Bool { isMusic && isFavorite != nil }
    /// `song repeat` (off/one/all) is Apple Music only.
    var canRepeat: Bool { isMusic && repeatMode != nil }
    /// Both players expose a shuffle toggle.
    var canShuffle: Bool { shuffleEnabled != nil }

    /// Equality over content only — `fetchedAt` is excluded so identical songs
    /// sampled at different times compare equal. Cheap fields are checked first
    /// so the (potentially large) artwork `Data` comparison is short-circuited
    /// whenever anything else differs.
    static func == (lhs: NowPlayingSong, rhs: NowPlayingSong) -> Bool {
        lhs.appName == rhs.appName
            && lhs.state == rhs.state
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.position == rhs.position
            && lhs.duration == rhs.duration
            && lhs.isFavorite == rhs.isFavorite
            && lhs.shuffleEnabled == rhs.shuffleEnabled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.albumArtURL == rhs.albumArtURL
            && lhs.albumArtData == rhs.albumArtData
    }

    /// Initializes a song model from a pipe-delimited AppleScript output string.
    ///
    /// Format (fields 6–8 optional): `state|title|artist|artURL|position|duration|loved|shuffling|repeat`.
    /// - Parameters:
    ///   - application: The name of the music application.
    ///   - output: The output string returned by AppleScript.
    init?(application: String, from output: String) {
        let c = output.components(separatedBy: "|")
        guard c.count >= 6, let state = PlaybackState(rawValue: c[0]) else {
            return nil
        }
        // Replace commas with dots for correct decimal conversion.
        let positionString = c[4].replacingOccurrences(of: ",", with: ".")
        let durationString = c[5].replacingOccurrences(of: ",", with: ".")
        guard let position = Double(positionString),
            let duration = Double(durationString)
        else {
            return nil
        }

        self.appName = application
        self.state = state
        self.title = c[1]
        self.artist = c[2]
        self.albumArtURL = URL(string: c[3])
        self.position = position
        // Spotify reports duration in milliseconds; Music in seconds.
        self.duration =
            application == MusicApp.spotify.rawValue ? duration / 1000 : duration

        // Optional capability fields — empty string means "unsupported" → nil.
        self.isFavorite = c.count > 6 ? Self.parseBool(c[6]) : nil
        self.shuffleEnabled = c.count > 7 ? Self.parseBool(c[7]) : nil
        self.repeatMode = c.count > 8 ? RepeatMode(rawValue: c[8]) : nil
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

// MARK: - Supported Music Applications

/// Supported music applications with corresponding AppleScript commands.
enum MusicApp: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    /// Bundle identifier, used for running-app checks. See `isAppRunning` for why
    /// this is matched instead of `localizedName`.
    var bundleId: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// AppleScript to fetch the now playing song (pipe-delimited).
    ///
    /// - `full: false` returns 6 core fields (state|title|artist|art|pos|dur) —
    ///   used while the popup is closed, since the menu bar doesn't show the
    ///   favorite/shuffle/repeat controls. Cheaper: fewer Apple Events per poll.
    /// - `full: true` appends `favorited|shuffle|repeat`, wrapped in `try` so an
    ///   unsupported property degrades to an empty field (→ control hidden)
    ///   rather than failing the whole fetch.
    ///
    /// Music never exposes a usable `URL of artwork` (that's why artwork is
    /// fetched separately as raw bytes), so we skip that read entirely and emit
    /// an empty art field, saving an Apple Event every poll.
    func nowPlayingScript(full: Bool) -> String {
        if self == .music {
            let extras = full ? """

                            try
                                set lovedText to (favorited of currentTrack) as text
                            on error
                                try
                                    set lovedText to (loved of currentTrack) as text
                                on error
                                    set lovedText to ""
                                end try
                            end try
                            try
                                set shuffleText to (shuffle enabled) as text
                            on error
                                set shuffleText to ""
                            end try
                            try
                                if (song repeat is off) then
                                    set repeatText to "off"
                                else if (song repeat is one) then
                                    set repeatText to "one"
                                else
                                    set repeatText to "all"
                                end if
                            on error
                                set repeatText to ""
                            end try
                """ : """

                            set lovedText to ""
                            set shuffleText to ""
                            set repeatText to ""
                """
            return """
                if application "Music" is running then
                    tell application "Music"
                        if player state is playing or player state is paused then
                            set currentTrack to current track
                            set stateText to "paused"
                            if player state is playing then set stateText to "playing"\(extras)
                            return stateText & "|" & (name of currentTrack) & "|" & (artist of currentTrack) & "|" & "" & "|" & (player position as text) & "|" & ((duration of currentTrack) as text) & "|" & lovedText & "|" & shuffleText & "|" & repeatText
                        else
                            return "stopped"
                        end if
                    end tell
                else
                    return "stopped"
                end if
                """
        } else {
            let shuffleRead = full ? """

                            try
                                set shuffleText to (shuffling) as text
                            on error
                                set shuffleText to ""
                            end try
                """ : """

                            set shuffleText to ""
                """
            return """
                if application "\(rawValue)" is running then
                    tell application "\(rawValue)"
                        if player state is playing or player state is paused then
                            set currentTrack to current track
                            set stateText to "paused"
                            if player state is playing then set stateText to "playing"\(shuffleRead)
                            return stateText & "|" & (name of currentTrack) & "|" & (artist of currentTrack) & "|" & (artwork url of currentTrack) & "|" & (player position as text) & "|" & ((duration of currentTrack) as text) & "|" & "" & "|" & shuffleText & "|" & ""
                        else
                            return "stopped"
                        end if
                    end tell
                else
                    return "stopped"
                end if
                """
        }
    }

    var previousTrackCommand: String {
        "tell application \"\(rawValue)\" to previous track"
    }

    var togglePlayPauseCommand: String {
        "tell application \"\(rawValue)\" to playpause"
    }

    var nextTrackCommand: String {
        "tell application \"\(rawValue)\" to next track"
    }

    /// Seeks to an absolute position (seconds). Reliable on Apple Music.
    func seekCommand(to seconds: Double) -> String {
        "tell application \"\(rawValue)\" to set player position to \(seconds)"
    }

    /// Sets shuffle on/off. Property name differs between players.
    func shuffleCommand(_ enabled: Bool) -> String {
        let property = self == .music ? "shuffle enabled" : "shuffling"
        return "tell application \"\(rawValue)\" to set \(property) to \(enabled)"
    }

    /// Sets the repeat mode (Apple Music only; `mode` is a bare AppleScript constant).
    func repeatCommand(_ mode: RepeatMode) -> String {
        "tell application \"\(rawValue)\" to set song repeat to \(mode.rawValue)"
    }

    /// Toggles the favorite flag on the current track (Apple Music only).
    /// Modern Music.app uses `favorited`; older versions use `loved`.
    func favoriteCommand(_ favorite: Bool) -> String {
        """
        tell application "\(rawValue)"
            try
                set favorited of current track to \(favorite)
            on error
                set loved of current track to \(favorite)
            end try
        end tell
        """
    }
}

// MARK: - Now Playing Provider

/// Provides functionality to fetch the now playing song and execute playback commands.
final class NowPlayingProvider {

    /// Caches the last fetched Apple Music artwork by track id, so we only
    /// re-invoke AppleScript for artwork when the track actually changes.
    private static var cachedArtwork: (trackId: String, data: Data)?

    /// Returns the current playing song from any supported music application.
    /// - Parameter full: fetch the extra favorite/shuffle/repeat fields (only
    ///   needed while the popup is open).
    static func fetchNowPlaying(full: Bool) -> NowPlayingSong? {
        for app in MusicApp.allCases {
            // Skip apps that aren't running — avoids compiling/executing an
            // AppleScript (an Apple Event round-trip) just to learn "stopped".
            guard isAppRunning(app) else { continue }
            if let song = fetchNowPlaying(from: app, full: full) {
                return song
            }
        }
        return nil
    }

    /// Returns the now playing song for a specific music application.
    private static func fetchNowPlaying(from app: MusicApp, full: Bool) -> NowPlayingSong? {
        guard
            let output = runAppleScript(
                app.nowPlayingScript(full: full), cached: true),
            output != "stopped"
        else {
            return nil
        }
        guard var song = NowPlayingSong(application: app.rawValue, from: output) else {
            return nil
        }

        // Music.app doesn't expose a usable artwork URL, so pull the
        // embedded artwork bytes directly instead.
        if app == .music, song.albumArtURL == nil {
            if let cached = cachedArtwork, cached.trackId == song.id {
                song.albumArtData = cached.data
            } else if let data = fetchMusicArtworkData() {
                song.albumArtData = data
                cachedArtwork = (song.id, data)
            }
        }

        return song
    }

    /// Fetches the current Apple Music track's raw artwork bytes via AppleScript.
    private static func fetchMusicArtworkData() -> Data? {
        let script = """
            tell application "Music"
                if player state is playing or player state is paused then
                    return data of artwork 1 of current track
                end if
            end tell
            """
        dispatchPrecondition(condition: .onQueue(scriptQueue))
        guard let appleScript = cachedScript(for: script) else { return nil }
        var error: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&error)
        guard error == nil, !descriptor.data.isEmpty else { return nil }
        return descriptor.data
    }

    // MARK: - Running-app tracking

    /// Bundle IDs of the supported players currently running.
    ///
    /// Maintained from workspace launch/terminate notifications rather than
    /// recomputed per poll. Scanning `NSWorkspace.shared.runningApplications` is
    /// deceptively expensive: *both* `localizedName` and `bundleIdentifier` fault
    /// in information from launchservicesd
    /// (`_fetchDynamicProperties` / `_fetchStaticInformationWithAtLeastKey:` →
    /// `_LSCopyApplicationInformation`), each a synchronous XPC round-trip. Doing
    /// that per player on every tick was a measurable chunk of idle CPU.
    private static var runningMusicApps: Set<String> = []
    private static let runningAppsLock = NSLock()

    /// Seeds the running-player cache and keeps it current. Idempotent.
    static func startTrackingRunningApps() {
        let musicIds = Set(MusicApp.allCases.map(\.bundleId))

        let initial = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        ).intersection(musicIds)
        runningAppsLock.lock()
        runningMusicApps = initial
        runningAppsLock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Bool)] = [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ]
        for (name, isRunning) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    let id = app.bundleIdentifier,
                    musicIds.contains(id)
                else { return }
                runningAppsLock.lock()
                if isRunning {
                    runningMusicApps.insert(id)
                } else {
                    runningMusicApps.remove(id)
                }
                runningAppsLock.unlock()
            }
        }
    }

    /// Checks if the specified music application is currently running.
    static func isAppRunning(_ app: MusicApp) -> Bool {
        runningAppsLock.lock()
        defer { runningAppsLock.unlock() }
        return runningMusicApps.contains(app.bundleId)
    }

    // MARK: - Compiled script cache

    /// Serial queue owning every `NSAppleScript` interaction.
    ///
    /// `NSAppleScript` is not thread-safe, and the cache below is shared mutable
    /// state that polls, popup refreshes and playback commands all reach for. All
    /// AppleScript work is funnelled through here so it stays single-threaded.
    static let scriptQueue = DispatchQueue(
        label: "com.barik-enhanced.applescript", qos: .userInitiated)

    /// Compiled polling scripts, keyed by source.
    ///
    /// The polling scripts are fixed strings (4 variants: Music/Spotify ×
    /// brief/full), but `NSAppleScript` re-parses and re-compiles from source on
    /// every `executeAndReturnError` against a fresh instance — `OSACompile` /
    /// `ASCompile` / `TASParser::Parse` showed up on every single poll. Compiling
    /// once and reusing removes that entirely.
    ///
    /// Only ever touched from `scriptQueue`.
    private static var compiledScripts: [String: NSAppleScript] = [:]

    /// Returns a compiled, cached script for `source`, compiling on first use.
    /// Must be called on `scriptQueue`.
    private static func cachedScript(for source: String) -> NSAppleScript? {
        if let existing = compiledScripts[source] { return existing }
        guard let script = NSAppleScript(source: source) else { return nil }
        var compileError: NSDictionary?
        guard script.compileAndReturnError(&compileError) else {
            print("AppleScript compile error: \(compileError ?? [:])")
            return nil
        }
        compiledScripts[source] = script
        return script
    }

    /// Executes the provided AppleScript and returns the trimmed result.
    ///
    /// - Parameter cached: reuse a compiled instance keyed by source. Safe only
    ///   for scripts with a fixed source; commands that interpolate a value
    ///   (seek position, shuffle state, …) must pass `false` or they'd populate
    ///   the cache with an unbounded number of one-shot entries.
    @discardableResult
    static func runAppleScript(_ script: String, cached: Bool = false) -> String? {
        dispatchPrecondition(condition: .onQueue(scriptQueue))
        let appleScript: NSAppleScript?
        if cached {
            appleScript = cachedScript(for: script)
        } else {
            appleScript = NSAppleScript(source: script)
        }
        guard let appleScript else { return nil }
        var error: NSDictionary?
        let outputDescriptor = appleScript.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript Error: \(error)")
            return nil
        }
        return outputDescriptor.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Returns the first running music application.
    static func activeMusicApp() -> MusicApp? {
        MusicApp.allCases.first { isAppRunning($0) }
    }

    /// Whether any supported player is running. Reads the cache, so the idle
    /// case costs a set lookup rather than a walk of every running application.
    static func anyMusicAppRunning() -> Bool {
        runningAppsLock.lock()
        defer { runningAppsLock.unlock() }
        return !runningMusicApps.isEmpty
    }

    /// Executes a playback command for the first running music application.
    ///
    /// Dispatched onto `scriptQueue`: these are fired from button handlers on the
    /// main thread, and an Apple Event round-trip has no business blocking it.
    static func executeCommand(_ command: @escaping (MusicApp) -> String) {
        guard let activeApp = activeMusicApp() else { return }
        scriptQueue.async { _ = runAppleScript(command(activeApp)) }
    }

    /// Executes a playback command targeting a specific app by name.
    /// Preferred over `executeCommand` so a command lands on the app the song
    /// actually belongs to (e.g. seeking Music even if Spotify is also open).
    static func executeCommand(
        on appName: String, _ command: @escaping (MusicApp) -> String
    ) {
        guard let app = MusicApp(rawValue: appName) else { return }
        scriptQueue.async { _ = runAppleScript(command(app)) }
    }

    /// Brings the given (or first running) music app to the foreground.
    static func activateApp(named appName: String?) {
        guard let app = appName.flatMap(MusicApp.init(rawValue:)) ?? activeMusicApp()
        else { return }
        guard
            let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == app.bundleId
            })
        else { return }
        running.activate(options: [.activateAllWindows])
    }
}

// MARK: - Now Playing Manager

/// An observable manager that periodically updates the now playing song.
final class NowPlayingManager: ObservableObject, ConditionallyActivatableWidget {
    static let shared = NowPlayingManager()

    @Published private(set) var nowPlaying: NowPlayingSong?
    /// Dominant color extracted from the current album art; used for subtle
    /// dynamic theming in the popup. Defaults to white when no art is available.
    @Published private(set) var accentColor: Color = .white
    /// True briefly while a track change is in flight, so the UI can show a
    /// loading state instead of stale metadata.
    @Published private(set) var isLoading: Bool = false

    private var cancellable: AnyCancellable?
    /// Poll interval dictated by the current performance mode.
    private var performanceInterval: TimeInterval = 5.0
    /// While the popup is open we poll faster for snappy external-change sync.
    private var popupVisible = false
    /// Effective poll interval: capped fast while the popup is visible.
    private var effectiveInterval: TimeInterval {
        popupVisible ? min(1.0, performanceInterval) : performanceInterval
    }

    let widgetId = "default.nowplaying"

    private var isActive = false
    private var accentCache: [String: Color] = [:]
    private var loadingTimeout: DispatchWorkItem?
    /// Tokens for the Music/Spotify distributed-notification observers.
    private var distributedObservers: [NSObjectProtocol] = []
    /// Debounce for notification-triggered refreshes.
    private var immediateRefreshWork: DispatchWorkItem?

    private init() {
        NowPlayingProvider.startTrackingRunningApps()
        setupNotifications()
        // For now, always activate to ensure widgets work
        activate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let dnc = DistributedNotificationCenter.default()
        for token in distributedObservers { dnc.removeObserver(token) }
    }

    private func setupNotifications() {
        // Listen for performance mode changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PerformanceModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let intervals = notification.object as? [String: TimeInterval],
                let newInterval = intervals["nowplaying"]
            {
                self?.updateTimerInterval(newInterval)
            }
        }

        // Event-driven refresh: Music and Spotify broadcast a distributed
        // notification the instant playback state or the track changes. Fetching on
        // those makes external changes (media keys, the app itself) reflect
        // immediately — independent of the performance-mode poll interval — without
        // polling any faster. (barik is non-sandboxed, so these are delivered.)
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            let token = dnc.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleImmediateRefresh()
            }
            distributedObservers.append(token)
        }
    }

    /// Coalesces the burst of playback notifications a single track/state change can
    /// emit into one fetch shortly after — instant to the eye, but never more than
    /// one AppleScript fetch per change, and only when the widget is active.
    private func scheduleImmediateRefresh() {
        guard isActive else { return }
        immediateRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateNowPlaying() }
        immediateRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func activate() {
        guard !isActive else {
            return
        }

        isActive = true

        // Get current performance mode interval
        let performanceManager = PerformanceModeManager.shared
        let intervals = performanceManager.getTimerIntervals(
            for: performanceManager.currentMode)
        performanceInterval = intervals["nowplaying"] ?? 5.0

        startTimer()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopTimer()

        // Clear the now playing info when deactivated
        DispatchQueue.main.async {
            self.nowPlaying = nil
        }
    }

    private func updateTimerInterval(_ newInterval: TimeInterval) {
        guard isActive else { return }
        performanceInterval = newInterval

        // Restart timer with new interval
        stopTimer()
        startTimer()
    }

    /// Called by the popup on appear/disappear. While visible we poll faster so
    /// external playback changes (media keys, other apps) reflect within ~1s;
    /// on close we revert to the performance-mode cadence — no idle busy-work.
    func setPopupVisible(_ visible: Bool) {
        guard popupVisible != visible else { return }
        popupVisible = visible
        guard isActive else { return }
        stopTimer()
        startTimer()
        if visible { updateNowPlaying() }
    }

    private func startTimer() {
        cancellable = Timer.publish(
            every: effectiveInterval, on: .main, in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            self?.updateNowPlaying()
        }
    }

    private func stopTimer() {
        cancellable?.cancel()
        cancellable = nil
    }

    /// Updates the now playing song asynchronously.
    private func updateNowPlaying() {
        // Only fetch the extra favorite/shuffle/repeat fields when the popup is
        // showing them; the menu bar doesn't need them.
        let full = popupVisible
        // No music app open means there is nothing to ask and no Apple Event to
        // send — skip the whole round-trip rather than scripting our way to "stopped".
        guard NowPlayingProvider.anyMusicAppRunning() else {
            if nowPlaying != nil { nowPlaying = nil }
            if accentColor != .white { accentColor = .white }
            finishLoading()
            return
        }
        // Runs on the serial AppleScript queue — see NowPlayingProvider.scriptQueue.
        NowPlayingProvider.scriptQueue.async { [weak self] in
            let song = NowPlayingProvider.fetchNowPlaying(full: full)
            DispatchQueue.main.async {
                guard let self else { return }
                let oldId = self.nowPlaying?.id
                if self.nowPlaying != song {
                    self.nowPlaying = song
                }
                if let song {
                    if song.id != oldId {
                        self.updateAccentColor(for: song)
                    }
                    // A resolved fetch clears any pending track-change loading.
                    self.finishLoading()
                } else {
                    if self.accentColor != .white { self.accentColor = .white }
                    self.finishLoading()
                }
            }
        }
    }

    // MARK: - Interpolation helper

    /// Best-estimate current playback position, advancing `position` by the time
    /// elapsed since it was sampled when playing. Used for optimistic freezes.
    private func currentInterpolatedPosition(of song: NowPlayingSong) -> Double? {
        guard let pos = song.position else { return nil }
        guard song.state == .playing, let dur = song.duration else { return pos }
        let elapsed = Date().timeIntervalSince(song.fetchedAt)
        return min(dur, pos + max(0, elapsed))
    }

    // MARK: - Accent color

    private func updateAccentColor(for song: NowPlayingSong) {
        let key = song.id
        if let cached = accentCache[key] {
            if accentColor != cached { accentColor = cached }
            return
        }
        let data = song.albumArtData
        let url = song.albumArtURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var image: NSImage?
            if let data { image = NSImage(data: data) }
            else if let url, let d = try? Data(contentsOf: url) {
                image = NSImage(data: d)
            }
            let color = image?.dominantColor() ?? .white
            DispatchQueue.main.async {
                guard let self else { return }
                self.accentCache[key] = color
                // Only apply if this is still the current track.
                if self.nowPlaying?.id == key {
                    self.accentColor = color
                }
            }
        }
    }

    // MARK: - Optimistic refresh scheduling

    /// After a control action, reconcile local optimistic state with reality by
    /// polling shortly after (twice, to catch fast track changes).
    private func scheduleQuickRefresh() {
        for delay in [0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.updateNowPlaying()
            }
        }
    }

    private func beginLoading() {
        isLoading = true
        loadingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isLoading = false }
        loadingTimeout = work
        // Safety net so the UI never gets stuck in a loading state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func finishLoading() {
        if isLoading { isLoading = false }
        loadingTimeout?.cancel()
        loadingTimeout = nil
    }

    // MARK: - Playback controls

    /// Skips to the previous track.
    func previousTrack() {
        runAppCommand { $0.previousTrackCommand }
        beginLoading()
        scheduleQuickRefresh()
    }

    /// Toggles between play and pause, updating local state immediately so the
    /// UI (icon, progress) responds instantly rather than waiting for the poll.
    func togglePlayPause() {
        runAppCommand { $0.togglePlayPauseCommand }
        guard var song = nowPlaying else {
            scheduleQuickRefresh()
            return
        }
        if song.state == .playing {
            // Pausing: freeze at the current interpolated position.
            song.position = currentInterpolatedPosition(of: song)
            song.fetchedAt = Date()
            song.state = .paused
        } else {
            // Resuming (or from stopped): re-anchor so interpolation continues.
            song.fetchedAt = Date()
            song.state = .playing
        }
        nowPlaying = song
        scheduleQuickRefresh()
    }

    /// Skips to the next track.
    func nextTrack() {
        runAppCommand { $0.nextTrackCommand }
        beginLoading()
        scheduleQuickRefresh()
    }

    /// Seeks to an absolute position in seconds (Apple Music only).
    func seek(to seconds: Double) {
        guard var song = nowPlaying, song.canSeek else { return }
        let clamped = max(0, min(song.duration ?? seconds, seconds))
        NowPlayingProvider.executeCommand(on: song.appName) {
            $0.seekCommand(to: clamped)
        }
        song.position = clamped
        song.fetchedAt = Date()
        nowPlaying = song
        scheduleQuickRefresh()
    }

    /// Toggles the loved/favorite flag on the current track (Apple Music only).
    func toggleFavorite() {
        guard var song = nowPlaying, song.canFavorite else { return }
        let newValue = !(song.isFavorite ?? false)
        NowPlayingProvider.executeCommand(on: song.appName) {
            $0.favoriteCommand(newValue)
        }
        song.isFavorite = newValue
        nowPlaying = song
        scheduleQuickRefresh()
    }

    /// Toggles shuffle (both players).
    func toggleShuffle() {
        guard var song = nowPlaying, song.canShuffle else { return }
        let newValue = !(song.shuffleEnabled ?? false)
        NowPlayingProvider.executeCommand(on: song.appName) {
            $0.shuffleCommand(newValue)
        }
        song.shuffleEnabled = newValue
        nowPlaying = song
        scheduleQuickRefresh()
    }

    /// Cycles repeat mode off → all → one → off (Apple Music only).
    func cycleRepeat() {
        guard var song = nowPlaying, song.canRepeat else { return }
        let next: RepeatMode
        switch song.repeatMode ?? .off {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        NowPlayingProvider.executeCommand(on: song.appName) {
            $0.repeatCommand(next)
        }
        song.repeatMode = next
        nowPlaying = song
        scheduleQuickRefresh()
    }

    /// Brings the currently playing music app to the foreground.
    func openApp() {
        NowPlayingProvider.activateApp(named: nowPlaying?.appName)
    }

    /// Runs a command against the current song's app when known, else the first
    /// running player.
    private func runAppCommand(_ command: @escaping (MusicApp) -> String) {
        if let appName = nowPlaying?.appName {
            NowPlayingProvider.executeCommand(on: appName, command)
        } else {
            NowPlayingProvider.executeCommand(command)
        }
    }
}
