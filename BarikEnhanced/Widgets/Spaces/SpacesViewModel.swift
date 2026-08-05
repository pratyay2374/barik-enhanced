import AppKit
import Combine
import os
import Foundation

class SpacesViewModel: ObservableObject, ConditionallyActivatableWidget {
    static let shared = SpacesViewModel()
    @Published var spaces: [AnySpace] = []
    private static let perfLog = Logger(subsystem: "com.barik-enhanced.perf", category: "spaces")
    private var timer: Timer?
    private var recoveryTimer: Timer?
    private var provider: AnySpacesProvider?
    private var currentProviderKind: ProviderKind?
    private var currentInterval: TimeInterval = 5.0
    private var lastEventLoadTime: CFAbsoluteTime = 0
    /// Last time `detectProviderKind()` ran, used to throttle the retry we keep
    /// for the "no window manager found yet" case. See `refreshProvider(force:)`.
    private var lastProviderDetectTime: CFAbsoluteTime = 0
    private static let providerDetectRetryInterval: CFAbsoluteTime = 30

    /// Safety-net poll interval used once the event path has proven itself.
    private static let backedOffInterval: TimeInterval = 30
    let widgetId = "default.spaces"
    
    private var isActive = false

    private enum ProviderKind: Equatable {
        case yabai
        case aerospace
    }

    private init() {
        setupNotifications()
        setupDarwinNotification()
        refreshProvider(force: true)
        // For now, always activate to ensure widgets work
        activate()
    }

    /// Listens for a Darwin notification posted by AeroSpace's
    /// `exec-on-workspace-change` / `on-focus-changed` hooks via
    /// `notifyutil -p com.barik-enhanced.aerospace-refresh`.
    /// This gives near-instant menu-bar updates on workspace/focus changes
    /// regardless of the polling interval set by the performance mode.
    private func setupDarwinNotification() {
        let callback: CFNotificationCallback = { _, _, _, _, _ in
            let start = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let model = SpacesViewModel.shared
                model.noteDarwinEventReceived()
                model.loadSpaces(source: "aerospace-event", triggerTime: start)
            }
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            callback,
            Self.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )

        // Trust the event path immediately when the hook is already in the config,
        // instead of polling at full rate until the first workspace switch.
        if Self.darwinHookIsConfigured {
            hasSeenDarwinEvent = true
        }
        Self.perfLog.notice(
            "darwin hook configured: \(self.hasSeenDarwinEvent, privacy: .public)")
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupNotifications() {
        // Listen for performance mode changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PerformanceModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let intervals = notification.object as? [String: TimeInterval],
               let newInterval = intervals["spaces"] {
                self?.updateTimerInterval(newInterval)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        // Instant refresh on app switch — avoids waiting for the poll timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadSpaces(source: "app-activation", triggerTime: CFAbsoluteTimeGetCurrent())
        }

        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("ConfigChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("ManualReloadTriggered"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceRefresh()
        }
        
        // For future use - widget activation/deactivation
        // NotificationCenter.default.addObserver(
        //     forName: NSNotification.Name("WidgetActivationChanged"),
        //     object: nil,
        //     queue: .main
        // ) { [weak self] notification in
        //     if let activeWidgets = notification.object as? Set<String> {
        //         if activeWidgets.contains(self?.widgetId ?? "") {
        //             self?.activate()
        //         } else {
        //             self?.deactivate()
        //         }
        //     }
        // }
    }
    
    func activate() {
        guard !isActive else { 
            return 
        }
        
        isActive = true
        
        // Get current performance mode interval
        let performanceManager = PerformanceModeManager.shared
        let intervals = performanceManager.getTimerIntervals(for: performanceManager.currentMode)
        currentInterval = intervals["spaces"] ?? 5.0
        
        startMonitoring()
    }
    
    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopMonitoring()
    }
    
    private func updateTimerInterval(_ newInterval: TimeInterval) {
        guard isActive else { return }
        currentInterval = newInterval
        
        // Restart timer with new interval
        stopMonitoring()
        startMonitoring()
    }

    /// Called from the Darwin notification callback. A single event proves the
    /// user has AeroSpace's `notifyutil` hooks wired up, which makes the poll
    /// timer redundant — so we drop to a long safety-net interval. Users without
    /// the hooks never call this and keep the original cadence.
    fileprivate func noteDarwinEventReceived() {
        guard !hasSeenDarwinEvent else { return }
        hasSeenDarwinEvent = true
        reconcileInterval()
    }

    /// Whether the event path can be trusted, so the poll can drop to a safety net.
    ///
    /// Deliberately latching rather than a rolling "saw an event recently" window:
    /// events only fire when the user *changes* workspace, so a time-decayed check
    /// would ramp polling back up precisely when the machine goes idle — the case
    /// we most want cheap. Hooks don't get unconfigured mid-session, and if they
    /// somehow do, the 30s safety poll and the 900s recovery timer still cover us.
    ///
    /// Seeded at startup from the AeroSpace config (see `darwinHookIsConfigured`)
    /// rather than waiting for the first event: otherwise every relaunch polls at
    /// the full rate until the user happens to switch workspace, which can be a
    /// long time on an idle machine — exactly when we want to be cheapest.
    private var hasSeenDarwinEvent = false

    /// Whether AeroSpace is configured to post the Darwin notification we listen
    /// for. Read once at startup; a `nil` config file simply means "unknown", and
    /// we fall back to proving it at runtime via `noteDarwinEventReceived()`.
    private static var darwinHookIsConfigured: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".aerospace.toml"),
            home.appendingPathComponent(".config/aerospace/aerospace.toml"),
        ]
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            // The hook has to post this exact name for our observer to fire, so an
            // exact substring match is the right test. Ignore commented-out lines.
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#") else { continue }
                if trimmed.contains(darwinNotificationName) { return true }
            }
        }
        return false
    }

    /// Darwin notification AeroSpace's hooks post via `notifyutil -p`.
    fileprivate static let darwinNotificationName =
        "com.barik-enhanced.aerospace-refresh"

    /// The interval the refresh timer should currently be running at.
    private var effectiveInterval: TimeInterval {
        hasSeenDarwinEvent
            ? max(Self.backedOffInterval, currentInterval) : currentInterval
    }

    /// Restarts the timer if the effective interval has drifted from the running
    /// one — i.e. events just started arriving, or the trust window lapsed.
    private func reconcileInterval() {
        guard isActive else { return }
        guard let timer, timer.timeInterval != effectiveInterval else { return }
        scheduleTimers()
    }

    private func startMonitoring() {
        scheduleTimers()
        loadSpaces()
    }

    /// Installs the refresh + recovery timers. Split out from `startMonitoring()`
    /// so `reconcileInterval()` can re-time the poll without forcing an extra load.
    private func scheduleTimers() {
        stopMonitoring()

        let interval = effectiveInterval
        Self.perfLog.notice(
            "spaces poll interval: \(interval, privacy: .public)s")
        let refreshTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.loadSpaces()
        }
        refreshTimer.tolerance = min(max(interval * 0.2, 0.1), 1.0)
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer

        let recoveryRefreshTimer = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            self?.forceRefresh()
        }
        recoveryRefreshTimer.tolerance = 60
        RunLoop.main.add(recoveryRefreshTimer, forMode: .common)
        recoveryTimer = recoveryRefreshTimer
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    fileprivate func loadSpaces(source: String = "timer", triggerTime: CFAbsoluteTime? = nil) {
        // Debounce event-driven calls: skip if another event-driven load
        // started within the last 100ms (a single switch fires 3 events)
        if let t = triggerTime {
            let now = CFAbsoluteTimeGetCurrent()
            if (now - lastEventLoadTime) < 0.1 {
                return
            }
            lastEventLoadTime = now
        }

        refreshProvider(force: false)

        // Use higher QoS for event-driven loads (user is waiting)
        let qos: DispatchQoS.QoSClass = triggerTime != nil ? .userInitiated : .background
        DispatchQueue.global(qos: qos).async { [weak self] in
            guard let self = self else { return }
            guard let provider = self.provider else {
                DispatchQueue.main.async {
                    if !self.spaces.isEmpty {
                        self.spaces = []
                    }
                }
                return
            }

            guard let spaces = provider.getSpacesWithWindows() else {
                DispatchQueue.main.async {
                    self.refreshProvider(force: true)
                }
                return
            }

            let sortedSpaces = spaces.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                let changed = sortedSpaces != self.spaces
                if changed {
                    self.spaces = sortedSpaces
                }
                if let t = triggerTime {
                    let latencyMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                    Self.perfLog.notice("[\(source, privacy: .public)] UI updated in \(String(format: "%.1f", latencyMs), privacy: .public)ms (changed: \(changed, privacy: .public))")
                }
            }
        }
    }

    func forceRefresh() {
        refreshProvider(force: true)
        loadSpaces()
    }

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.refreshProvider(force: false)
            self.provider?.focusSpace(
                spaceId: space.id, needWindowFocus: needWindowFocus)
        }
    }

    func switchToWindow(_ window: AnyWindow) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.refreshProvider(force: false)
            self.provider?.focusWindow(windowId: String(window.id))
        }
    }

    /// Re-resolves which window manager we're talking to.
    ///
    /// `detectProviderKind()` is far more expensive than it looks: reading
    /// `localizedName` off an `NSRunningApplication` faults in dynamic properties
    /// via `_LSCopyApplicationInformation`, i.e. one *synchronous* XPC round-trip
    /// to launchservicesd per running app. On a busy machine that's ~100 blocking
    /// IPC calls, and `loadSpaces()` used to trigger it on the main thread every
    /// poll — to recompute a value that never changes in practice.
    ///
    /// So the poll path now reuses the cached kind. Detection still runs when it
    /// can actually change: `didLaunch`/`didTerminate`/`didWake` and friends all
    /// route through `forceRefresh()`. The throttled nil-case retry is a safety
    /// net for window managers that run as bare daemons and may therefore never
    /// post an app-launch notification.
    private func refreshProvider(force: Bool) {
        if !force, currentProviderKind != nil { return }

        if !force {
            let now = CFAbsoluteTimeGetCurrent()
            guard (now - lastProviderDetectTime) >= Self.providerDetectRetryInterval
            else { return }
            lastProviderDetectTime = now
        } else {
            lastProviderDetectTime = CFAbsoluteTimeGetCurrent()
        }

        let nextKind = detectProviderKind()
        guard force || nextKind != currentProviderKind else {
            return
        }

        currentProviderKind = nextKind
        provider = switch nextKind {
        case .yabai:
            AnySpacesProvider(YabaiSpacesProvider())
        case .aerospace:
            AnySpacesProvider(AerospaceSpacesProvider())
        case .none:
            nil
        }
    }

    private func detectProviderKind() -> ProviderKind? {
        let runningApps = Set(
            NSWorkspace.shared.runningApplications.compactMap {
                $0.localizedName?.lowercased()
            }
        )

        if runningApps.contains("yabai") {
            return .yabai
        }

        if runningApps.contains("aerospace") {
            return .aerospace
        }

        return nil
    }
}

class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {}
    func icon(for appName: String) -> NSImage? {
        if let cached = cache.object(forKey: appName as NSString) {
            return cached
        }
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName == appName
        }),
            let bundleURL = app.bundleURL
        {
            let icon = workspace.icon(forFile: bundleURL.path)
            cache.setObject(icon, forKey: appName as NSString)
            return icon
        }
        return nil
    }
}
