import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var backgroundPanels: [NSPanel] = []
    private var menuBarPanels: [NSPanel] = []
    private var nativeMenuBarIsVisible = false
    private var nativeMenuBarObserver: NativeMenuBarVisibilityObserver?

    // On current macOS, MenuBarAgent keeps a transparent status-level window
    // across the top strip even with the native menu bar hidden. A backstop-
    // menu panel is visible underneath it but never receives mouse clicks.
    private static let menuBarWindowLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need the app process for @testable import, but must
        // not create panels or trip the production single-instance guard.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
            != nil
        {
            return
        }

        // Prevent multiple instances
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            NSApp.terminate(nil)
            return
        }

        if let error = ConfigManager.shared.initError {
            showFatalConfigError(message: error)
            return
        }
        
        // Show "What's New" banner if the app version is outdated
        if !VersionChecker.isLatestVersion() {
            VersionChecker.updateVersionFile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(
                    name: Notification.Name("ShowWhatsNewBanner"), object: nil)
            }
        }
        
        MenuBarPopup.setup()
        MenuBarMetrics.shared.startDetecting()
        setupPanels()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationDidChange(_:)),
            name: NSNotification.Name("ConfigChanged"),
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil)
    }

    @objc private func configurationDidChange(_ notification: Notification) {
        setupPanels()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        MenuBarPopup.setup()
        setupPanels()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MenuBarMetrics.shared.restartDetection()
            MenuBarPopup.setup()
            self?.setupPanels()
        }
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MenuBarMetrics.shared.restartDetection()
            MenuBarPopup.setup()
            self?.setupPanels()
        }
    }

    @objc private func screensDidWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MenuBarMetrics.shared.restartDetection()
            MenuBarPopup.setup()
            self?.setupPanels()
        }
    }

    /// Configures and displays the background and menu bar panels.
    func setupPanels() {
        if nativeMenuBarObserver == nil {
            nativeMenuBarIsVisible = NSMenu.menuBarVisible()
            nativeMenuBarObserver = NativeMenuBarVisibilityObserver { [weak self] visible in
                self?.nativeMenuBarIsVisible = visible
                self?.applyNativeMenuBarVisibility()
            }
        }

        let monitorMode = ConfigManager.shared.config.monitors.mode
        let screens: [NSScreen]

        switch monitorMode {
        case .main:
            if let mainScreen = NSScreen.main {
                screens = [mainScreen]
            } else {
                return
            }
        case .all:
            screens = NSScreen.screens
        }

        // Remove excess panels if screens were reduced
        while backgroundPanels.count > screens.count {
            backgroundPanels.removeLast().close()
        }
        while menuBarPanels.count > screens.count {
            menuBarPanels.removeLast().close()
        }

        // Create or update panels for each screen
        let isBottom = ConfigManager.shared.config.experimental.position == .bottom
        let foregroundHeight = ConfigManager.shared.config.experimental.foreground.resolveHeight()

        for (index, screen) in screens.enumerated() {
            let screenFrame = screen.frame

            // The menu bar panel should only cover the strip where widgets live,
            // not the full screen. This lets clicks pass through to the desktop.
            let menuBarFrame: CGRect = {
                if isBottom {
                    return CGRect(
                        x: screenFrame.origin.x,
                        y: screenFrame.origin.y,
                        width: screenFrame.width,
                        height: foregroundHeight
                    )
                } else {
                    return CGRect(
                        x: screenFrame.origin.x,
                        y: screenFrame.origin.y + screenFrame.height - foregroundHeight,
                        width: screenFrame.width,
                        height: foregroundHeight
                    )
                }
            }()

            if index < backgroundPanels.count {
                // Update existing panel — re-apply frame and level to recover from
                // corrupted state after system crashes or sleep/wake cycles
                backgroundPanels[index].setFrame(screenFrame, display: true)
                backgroundPanels[index].ignoresMouseEvents = true
                backgroundPanels[index].level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                backgroundPanels[index].orderFront(nil)
                menuBarPanels[index].setFrame(menuBarFrame, display: true)
                menuBarPanels[index].level = Self.menuBarWindowLevel
            } else {
                // Create new panels
                let backgroundPanel = createPanel(
                    frame: screenFrame,
                    level: Int(CGWindowLevelForKey(.desktopWindow)),
                    hostingRootView: AnyView(BackgroundView(screen: screen)),
                    ignoresMouse: true
                )
                let menuBarPanel = createPanel(
                    frame: menuBarFrame,
                    level: Self.menuBarWindowLevel.rawValue,
                    hostingRootView: AnyView(MenuBarView()),
                    ignoresMouse: false
                )
                backgroundPanels.append(backgroundPanel)
                menuBarPanels.append(menuBarPanel)
            }
        }
        applyNativeMenuBarVisibility()
    }

    private func applyNativeMenuBarVisibility() {
        let yieldToNativeMenu = nativeMenuBarIsVisible
            && ConfigManager.shared.config.experimental.position == .top
        for panel in menuBarPanels {
            panel.ignoresMouseEvents = yieldToNativeMenu
            panel.alphaValue = yieldToNativeMenu ? 0 : 1
            if yieldToNativeMenu {
                // Lowering the window alone can leave widgets visible through
                // native glass. Remove the foreground from display and hit tests.
                panel.orderOut(nil)
            } else {
                panel.level = Self.menuBarWindowLevel
                panel.orderFront(nil)
            }
        }
    }

    /// Creates an NSPanel with the provided parameters.
    func createPanel(
        frame: CGRect, level: Int, hostingRootView: AnyView,
        ignoresMouse: Bool = false
    ) -> NSPanel {
        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = NSWindow.Level(rawValue: level)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.isReleasedWhenClosed = false
        newPanel.ignoresMouseEvents = ignoresMouse
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Host the SwiftUI view inside a plain container: an NSHostingView with
        // empty content (the disabled background) reports a zero fitting size
        // and collapses the panel, hiding the background after it is enabled.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let hostingView = FirstMouseHostingView(rootView: hostingRootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        container.addSubview(hostingView)
        newPanel.contentView = container
        newPanel.setFrame(frame, display: true)
        newPanel.orderFront(nil)
        return newPanel
    }
    
    private func showFatalConfigError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Configuration Error"
        alert.informativeText = "\(message)\n\nPlease double check ~/.barik-config.toml and try again."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
