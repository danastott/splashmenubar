import XCTest
import SwiftUI
import AppKit
@testable import SplashMenuBar

final class GaugeColorPanelTests: XCTestCase {
    func testPanelEditsUpdateGaugeAndCoalesceTheSave() {
        var live: [(String, Color)] = []
        var commits = 0
        let panel = GaugeColorPanel(
            onLive: { live.append(($0, $1)) },
            onCommit: { commits += 1 })
        panel.bind(id: "tok")
        panel.handleColor(NSColor.systemRed)
        panel.handleColor(NSColor.systemBlue)

        XCTAssertEqual(live.count, 2, "every panel edit reaches the gauge live")
        XCTAssertEqual(live.map { $0.0 }, ["tok", "tok"])
        XCTAssertEqual(commits, 0, "no write while the burst is still going")

        let done = expectation(description: "coalesced save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(commits, 1, "one write for the whole burst")
    }

    func testRebindingAnotherGaugeDiscardsThePendingSave() {
        var live: [(String, Color)] = []
        var commits = 0
        let panel = GaugeColorPanel(
            onLive: { live.append(($0, $1)) },
            onCommit: { commits += 1 })
        panel.bind(id: "tok")
        panel.handleColor(NSColor.systemRed)
        panel.bind(id: "gpu")
        panel.handleColor(NSColor.systemGreen)

        let done = expectation(description: "save for the second gauge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(commits, 1, "only the second burst is written")
        XCTAssertEqual(live.map { $0.0 }, ["tok", "gpu"])
    }

    func testColorsWithoutABoundGaugeAreIgnored() {
        var live: [(String, Color)] = []
        let panel = GaugeColorPanel(
            onLive: { live.append(($0, $1)) }, onCommit: {})
        panel.handleColor(NSColor.systemRed)
        XCTAssertTrue(live.isEmpty)
    }
}
