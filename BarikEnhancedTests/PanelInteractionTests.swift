import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import BarikEnhanced

@MainActor
final class PanelInteractionTests: XCTestCase {
    func testMenuBarPanelDeliversMouseClicksToHostedWidget() throws {
        var clicks = 0
        let delegate = AppDelegate()
        let panel = delegate.createPanel(
            frame: NSRect(x: 100, y: 100, width: 300, height: 33),
            level: Int(CGWindowLevelForKey(.backstopMenu)),
            hostingRootView: AnyView(
                Text("Test widget")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { clicks += 1 }))
        defer { panel.close() }
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: kind,
                location: NSPoint(x: 150, y: 16),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: kind == .leftMouseDown ? 1 : 0))
            panel.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(clicks, 1, "A real mouse-down/up pair must reach the widget's tap gesture")
    }

    func testSettingsMenuOpensFromMenuBarPanel() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try """
        [widgets]
        displayed = []
        [experimental.foreground]
        height = 33
        horizontal-padding = 20
        """.write(to: fixture, atomically: true, encoding: .utf8)
        ConfigManager.shared.parseConfigFile(at: fixture.path)
        XCTAssertEqual(
            ConfigManager.shared.config.experimental.foreground.resolveHeight(), 33,
            "Startup panels must use the parsed height immediately, before the next run-loop turn")
        defer {
            try? "[widgets]\ndisplayed = []\n".write(to: fixture, atomically: true, encoding: .utf8)
            ConfigManager.shared.parseConfigFile(at: fixture.path)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try? FileManager.default.removeItem(at: fixture)
        }
        MenuBarPopup.setup()
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let delegate = AppDelegate()
        delegate.setupPanels()
        let created = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        defer { created.forEach { $0.close() } }
        try sendNativeMenuEvent(UInt32(kEventMenuBarHidden))
        let panel = try XCTUnwrap(created.first { !$0.ignoresMouseEvents })
        XCTAssertEqual(panel.frame.height, 33)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        panel.contentView?.layoutSubtreeIfNeeded()
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: kind, location: NSPoint(x: panel.frame.width - 29, y: 16.5),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 2,
                clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
            panel.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(MenuBarPopup.lastContentIdentifier, "settings")
    }

    func testProductionMenuBarStaysAboveNativeMenuBarHitArea() throws {
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let delegate = AppDelegate()
        delegate.setupPanels()
        let created = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        defer { created.forEach { $0.close() } }
        try sendNativeMenuEvent(UInt32(kEventMenuBarHidden))
        let bar = try XCTUnwrap(created.first { !$0.ignoresMouseEvents })
        XCTAssertGreaterThan(
            bar.level.rawValue, NSWindow.Level.statusBar.rawValue,
            "The transparent native MenuBarAgent hit area must not intercept Barik widget clicks")
        bar.level = .normal
        delegate.setupPanels()
        XCTAssertGreaterThan(
            bar.level.rawValue, NSWindow.Level.statusBar.rawValue,
            "Display/wake recovery must restore the interactive bar level")
        let background = try XCTUnwrap(created.first { $0.ignoresMouseEvents })
        XCTAssertLessThan(background.level.rawValue, NSWindow.Level.normal.rawValue)
    }

    func testNativeMenuTakesOverAndRestoresClickableBar() throws {
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let delegate = AppDelegate()
        delegate.setupPanels()
        let created = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        defer { created.forEach { $0.close() } }
        let bar = try XCTUnwrap(created.first { $0.level.rawValue > NSWindow.Level.normal.rawValue })

        try sendNativeMenuEvent(UInt32(kEventMenuBarHidden))
        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.ignoresMouseEvents)

        try sendNativeMenuEvent(UInt32(kEventMenuBarShown))
        XCTAssertFalse(bar.isVisible, "Barik must not cover or bleed through the revealed native menu")
        XCTAssertTrue(bar.ignoresMouseEvents, "Native-menu clicks must not reach Barik")
        XCTAssertEqual(bar.alphaValue, 0, "The foreground must not remain composited over native glass")

        delegate.setupPanels()
        XCTAssertFalse(bar.isVisible, "A config/display refresh must not bring Barik over the visible native menu")

        try sendNativeMenuEvent(UInt32(kEventMenuBarHidden))
        XCTAssertTrue(bar.isVisible, "Barik must return when the native menu hides")
        XCTAssertFalse(bar.ignoresMouseEvents)
        XCTAssertEqual(bar.alphaValue, 1)
        XCTAssertGreaterThan(bar.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }

    func testBottomBarRemainsAvailableWhileNativeMenuIsShown() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try """
        [widgets]
        displayed = []
        [experimental]
        position = "bottom"
        """.write(to: fixture, atomically: true, encoding: .utf8)
        ConfigManager.shared.parseConfigFile(at: fixture.path)
        defer {
            try? "[widgets]\ndisplayed = []\n".write(to: fixture, atomically: true, encoding: .utf8)
            ConfigManager.shared.parseConfigFile(at: fixture.path)
            try? FileManager.default.removeItem(at: fixture)
        }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let delegate = AppDelegate()
        delegate.setupPanels()
        let created = NSApp.windows.filter { !existing.contains($0.windowNumber) }
        defer { created.forEach { $0.close() } }
        let bar = try XCTUnwrap(created.first { $0.level.rawValue > NSWindow.Level.normal.rawValue })
        try sendNativeMenuEvent(UInt32(kEventMenuBarShown))
        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.ignoresMouseEvents)
        try sendNativeMenuEvent(UInt32(kEventMenuBarHidden))
    }

    private func sendNativeMenuEvent(_ kind: UInt32) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassMenu), kind, GetCurrentEventTime(), 0, &event), noErr)
        let nativeEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(nativeEvent) }
        // Deliver the same documented event AppKit receives, only to this test
        // application's dispatcher. This does not change system settings or menus.
        _ = SendEventToEventTarget(nativeEvent, GetEventDispatcherTarget())
    }

}
