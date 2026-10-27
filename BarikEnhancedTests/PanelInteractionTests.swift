import AppKit
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

}
