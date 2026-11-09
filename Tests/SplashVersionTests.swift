import XCTest
@testable import SplashMenuBar

final class SplashVersionTests: XCTestCase {
    func testNumericSegments() {
        XCTAssertTrue(SplashVersion.isNewer("1.6.1", over: "1.6.0"))
        XCTAssertFalse(SplashVersion.isNewer("1.6.0", over: "1.6.0"))
        XCTAssertFalse(SplashVersion.isNewer("1.5.0", over: "1.6.0"))
        // Numeric, not lexicographic: 10 > 9.
        XCTAssertTrue(SplashVersion.isNewer("1.10.0", over: "1.9.9"))
        XCTAssertTrue(SplashVersion.isNewer("2.0", over: "1.9.9"))
    }

    func testUnequalLength() {
        // A build with no extra segment is not "newer" than one with it.
        XCTAssertFalse(SplashVersion.isNewer("1.6.0", over: "1.6.0.1"))
        XCTAssertTrue(SplashVersion.isNewer("1.6.0.1", over: "1.6.0"))
    }

    func testNonNumericSegments() {
        // A non-numeric tail compares as a string; the pure number sorts
        // before the suffixed one.
        XCTAssertFalse(SplashVersion.isNewer("1.6.0", over: "1.6.0-rc1"))
        XCTAssertTrue(SplashVersion.isNewer("1.6.0-rc1", over: "1.6.0-beta"))
    }

    func testUpdateAvailableFlag() {
        let store = MetricsStore()
        XCTAssertFalse(store.updateAvailable, "nothing known yet")
        store.installedVersion = "1.5.0"
        XCTAssertFalse(store.updateAvailable, "no latest release seen yet")
        store.latestVersion = "1.5.0"
        XCTAssertFalse(store.updateAvailable, "already on the latest")
        store.latestVersion = "1.6.0"
        XCTAssertTrue(store.updateAvailable)
        store.installedVersion = nil
        XCTAssertFalse(store.updateAvailable, "splash not installed")
    }
}
