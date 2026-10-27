import AppKit
import SwiftUI
import XCTest
@testable import BarikEnhanced

@MainActor
final class SystemMonitorRenderingTests: XCTestCase {
    func testProcessSamplerReturnsSaneRows() {
        let processes = ProcessSampler.sample()

        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(processes.contains { $0.memoryBytes > 0 })
        XCTAssertTrue(processes.allSatisfy { $0.id > 1 && !$0.name.isEmpty })
    }

    func testTopProcessSectionRendersBothMetrics() throws {
        let processes = [
            TopProcess(
                id: 501,
                name: "Google Chrome Helper",
                cpuPercent: 42.5,
                memoryBytes: 1_610_612_736),
            TopProcess(
                id: 733,
                name: "WindowServer",
                cpuPercent: 12.0,
                memoryBytes: 402_653_184),
            TopProcess(
                id: 918,
                name: "opencode",
                cpuPercent: 3.4,
                memoryBytes: 998_244_352),
        ]

        try render(
            TopProcessSection(
                cpuProcesses: processes,
                ramProcesses: processes,
                onKill: { _ in })
                .padding(12)
                .frame(width: 320)
                .background(.black),
            named: "barik-top-processes")
    }

    func testForkPopupsRenderWithSharedHistories() throws {
        // ImageRenderer does not draw AppKit-backed scroll views. Capture the
        // hosting view so this exercises the CPU popup's scrollable viewport.
        let host = NSHostingView(
            rootView: CPURAMPopup().frame(height: 580).background(.black))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 580)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/barik-fork-cpu-popup.png"))
        let hasVisibleContent = stride(from: 0, to: bitmap.pixelsHigh, by: 10).contains { y in
            stride(from: 0, to: bitmap.pixelsWide, by: 10).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2
            }
        }
        XCTAssertTrue(hasVisibleContent, "CPU popup must contain visible content")
        try render(
            NetworkActivityPopup().background(.black),
            named: "barik-fork-network-popup")
    }

    private func render<Content: View>(
        _ content: Content,
        named name: String
    ) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:]))
        let outputURL = URL(fileURLWithPath: "/tmp/\(name).png")

        try pngData.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(pngData.count, 1_000)
        XCTAssertGreaterThan(image.size.width, 40)
        XCTAssertGreaterThan(image.size.height, 20)
    }
}
