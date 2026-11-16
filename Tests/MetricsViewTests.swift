import XCTest
@testable import SplashMenuBar

final class MetricsViewTests: XCTestCase {
    private func makeStore() -> MetricsStore {
        let store = MetricsStore()
        store.state = .running
        store.endpointAlive = true
        store.endpointReady = true
        store.readyModel = "owner/repo"
        return store
    }

    private func headerHelp(_ store: MetricsStore) -> String {
        MetricsView(store: store, config: .default, onAction: { _ in }).statusHelp
    }

    func testStatusHelpShowsServerVersion() {
        let store = makeStore()
        store.serverVersion = "1.6.0"
        XCTAssertEqual(
            headerHelp(store),
            "Green: splash is running and ready for requests.\nsplash 1.6.0")
        // No server version known yet: the plain status line.
        store.serverVersion = nil
        XCTAssertEqual(
            headerHelp(store),
            "Green: splash is running and ready for requests.")
    }

    func testStatusHelpStartingUpShowsServerVersion() {
        let store = makeStore()
        store.state = .starting
        store.endpointReady = false
        store.readyModel = nil
        store.serverVersion = "1.5.0"
        XCTAssertEqual(
            headerHelp(store),
            "Yellow: splash is starting (downloading or loading the model).\nsplash 1.5.0")
    }

    private func view(_ store: MetricsStore) -> MetricsView {
        MetricsView(store: store, config: .default, onAction: { _ in })
    }

    func testTokGaugeScaleAutoScalesAbove100() {
        let store = makeStore()
        store.tpsHistory = [40, 55]
        store.liveTokensPerSecond = 180
        // The old hard-coded 100 pinned the ring; now full ring = 200,
        // the round number at or above the peak.
        XCTAssertEqual(view(store).tpsScale, 200)
    }

    func testTokGaugeScaleKeeps100ForSlowerServers() {
        let store = makeStore()
        store.tpsHistory = [60, 80]
        store.liveTokensPerSecond = 90
        XCTAssertEqual(view(store).tpsScale, 100)
    }

    func testTokGaugeScaleUsesWindowMaxWhenIdle() {
        let store = makeStore()
        // No live batch (idle): the ring still scales to the window's peak,
        // so an old burst keeps the ring readable.
        store.tpsHistory = [120, 149]
        XCTAssertEqual(view(store).tpsScale, 150)
    }

    func testTokGaugeScaleIgnoresSamplesOutsideWindow() {
        let store = makeStore()
        // The default window is 150 samples; the oldest one is out of it.
        store.tpsHistory = [999] + Array(repeating: 40.0, count: 150)
        XCTAssertEqual(view(store).tpsScale, 40)
    }

    func testTokGaugeScaleWithNoData() {
        let store = makeStore()
        XCTAssertEqual(view(store).tpsScale, 1)
    }

    func testAppUpdateAvailableOnlyForNewerReleases() {
        let store = makeStore()
        store.appInstalledVersion = "1.0.3"
        XCTAssertFalse(store.appUpdateAvailable, "no check result yet")
        store.appLatestVersion = "1.0.3"
        XCTAssertFalse(store.appUpdateAvailable, "same version")
        // Numeric compare, not string: "1.0.10" sorts below "1.0.3" as text.
        store.appLatestVersion = "1.0.10"
        XCTAssertTrue(store.appUpdateAvailable)
        store.appInstalledVersion = "1.1.0"
        XCTAssertFalse(store.appUpdateAvailable, "already newer")
    }
}
