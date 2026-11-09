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
}
