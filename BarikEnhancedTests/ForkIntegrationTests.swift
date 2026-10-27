import TOMLDecoder
import XCTest
@testable import BarikEnhanced

final class ForkIntegrationTests: XCTestCase {
    func testBackgroundTogglePreservesCustomBackgroundAndAgentThresholds() throws {
        let original = """
        [widgets]
        displayed = ["default.agent-usage", "default.meetings", "default.clipboard", "default.wireguard", "default.syncthing"]

        [widgets.default.agent-usage.claude] # fork-specific settings
        warning-threshold = 65
        critical-threshold = 85

        [experimental.background] # custom background
        displayed = true
        blur = 4
        blurRadius = 15
        opacity = 0.4
        color = "#112233"
        """
        let updated = ConfigManager.shared.updatedTOMLString(
            original: original,
            key: "experimental.background.displayed",
            newValue: "false",
            wrapInQuotes: false)
        let config = try TOMLDecoder().decode(RootToml.self, from: updated)
        let background = try XCTUnwrap(config.experimental?.background)

        XCTAssertFalse(background.displayed)
        XCTAssertEqual(background.blurRadius, 15)
        XCTAssertEqual(background.opacity, 0.4)
        XCTAssertEqual(background.color, "#112233")
        XCTAssertEqual(background.wallpaperBlurRadius, 36)
        XCTAssertEqual(config.widgets.displayed.map(\.id), [
            "default.agent-usage", "default.meetings", "default.clipboard",
            "default.wireguard", "default.syncthing",
        ])
        XCTAssertEqual(
            config.widgets.config(for: "default.agent-usage")?["claude"]?
                .dictionaryValue?["warning-threshold"]?.intValue,
            65)
    }

    func testBackgroundBlurClampsLegacyIntensityAndRetainsBlackMode() throws {
        for (intensity, black, radius) in [(-1, false, 12), (3, false, 26), (7, true, 60), (99, true, 60)] {
            let background = try TOMLDecoder().decode(
                BackgroundConfig.self, from: "blur = \(intensity)")
            XCTAssertEqual(background.black, black)
            XCTAssertEqual(background.wallpaperBlurRadius, CGFloat(radius))
            XCTAssertNil(background.blurRadius)
        }
    }

    func testUnifiedAgentUsageAndNewWidgetsAreAvailableWithoutLegacyDuplicates() {
        for id in ["default.agent-usage", "default.meetings", "default.clipboard", "default.wireguard", "default.syncthing"] {
            XCTAssertEqual(allWidgets.filter { $0.id == id }.count, 1)
            XCTAssertEqual(MenuBarContextMenu.widgetEntries.filter { $0.id == id }.count, 1)
        }
        for id in ["default.claude-usage", "default.codex-usage", "default.opencode-usage"] {
            XCTAssertFalse(allWidgets.contains { $0.id == id })
            XCTAssertFalse(MenuBarContextMenu.widgetEntries.contains { $0.id == id })
        }
    }
}
