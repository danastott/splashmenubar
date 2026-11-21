import XCTest
@testable import SplashMenuBar

final class StatsStoreTests: XCTestCase {

    private func cleanStore() {
        let url = StatsStore.statsURL()
        try? FileManager.default.removeItem(at: url)
        StatsStore.shared.resetForTesting()
    }

    override func setUp() {
        super.setUp()
        cleanStore()
    }

    override func tearDown() {
        cleanStore()
        super.tearDown()
    }

    func testNewStoreHasNoBaseline() {
        let store = StatsStore.shared
        XCTAssertNil(store.today.baselineCompleted)
        XCTAssertNil(store.today.baselineOutputTokens)
        XCTAssertNil(store.today.completedToday(current: nil))
    }

    func testUpdateBaselinesSetsOnFirstSight() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 10, output: 1000, serverPort: 8081)
        XCTAssertEqual(store.today.baselineCompleted, 10)
        XCTAssertEqual(store.today.baselineOutputTokens, 1000)
    }

    func testUpdateBaselinesKeepsFirstBaseline() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 10, output: 1000, serverPort: 8081)
        // Later polls with higher counters must not move the baseline.
        store.updateBaselines(completed: 12, output: 1500, serverPort: 8081)
        XCTAssertEqual(store.today.baselineCompleted, 10)
        XCTAssertEqual(store.today.baselineOutputTokens, 1000)
    }

    func testUpdateBaselinesRebaselinesAfterRestart() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 100, output: 5000, serverPort: 8081)
        // Server restart: lifetime counters reset below the baseline.
        store.updateBaselines(completed: 2, output: 300, serverPort: 8081)
        XCTAssertEqual(store.today.baselineCompleted, 2)
        XCTAssertEqual(store.today.baselineOutputTokens, 300)
    }

    func testUpdateBaselinesRebaselinesOnServerSwitch() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 10, output: 1000, serverPort: 8081)
        // Switch to a different server whose lifetime counters are HIGHER:
        // without a fresh baseline, today's delta would swallow that
        // server's entire lifetime.
        store.updateBaselines(completed: 500, output: 90000, serverPort: 8082)
        XCTAssertEqual(store.today.baselineCompleted, 500)
        XCTAssertEqual(store.today.baselineOutputTokens, 90000)
        XCTAssertEqual(store.today.completedToday(current: 500), 0)
        XCTAssertEqual(store.today.completedToday(current: 512), 12)
    }

    func testUpdateBaselinesRebaselinesWhenSwitchingBack() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 10, output: 1000, serverPort: 8081)
        store.updateBaselines(completed: 500, output: 90000, serverPort: 8082)
        // Back to the original server, same day: re-baseline again from
        // its current counters.
        store.updateBaselines(completed: 12, output: 1500, serverPort: 8081)
        XCTAssertEqual(store.today.baselineCompleted, 12)
        XCTAssertEqual(store.today.baselineOutputTokens, 1500)
    }

    func testCompletedTodayIsDeltaFromBaseline() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 10, output: 1000, serverPort: 8081)
        XCTAssertEqual(store.today.completedToday(current: 10), 0)
        XCTAssertEqual(store.today.completedToday(current: 15), 5)
        XCTAssertEqual(store.today.completedToday(current: 3), 0) // clamped
        XCTAssertEqual(store.today.completedToday(current: nil), nil)
    }

    func testOutputTodayIsDeltaFromBaseline() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 0, output: 1000, serverPort: 8081)
        XCTAssertEqual(store.today.outputToday(current: 1000), 0)
        XCTAssertEqual(store.today.outputToday(current: 2500), 1500)
        XCTAssertEqual(store.today.outputToday(current: nil), nil)
    }

    func testOutputTodayNilBeforeBaseline() {
        let store = StatsStore.shared
        // No baseline recorded yet.
        XCTAssertEqual(store.today.outputToday(current: 500), nil)
        XCTAssertEqual(store.today.completedToday(current: 5), nil)
    }

    func testAccumulateRequestSumsTTFT() {
        let store = StatsStore.shared
        store.accumulateRequest(ttft: 0.4, tps: nil)
        store.accumulateRequest(ttft: 0.6, tps: nil)
        XCTAssertEqual(store.today.avgTTFT!, 0.5, accuracy: 0.001)
        XCTAssertEqual(store.today.ttftCount, 2)
    }

    func testAccumulateRequestSumsTokPerSecond() {
        let store = StatsStore.shared
        store.accumulateRequest(ttft: nil, tps: 40.0)
        store.accumulateRequest(ttft: nil, tps: 60.0)
        XCTAssertEqual(store.today.avgTokPerSecond!, 50.0, accuracy: 0.001)
        XCTAssertEqual(store.today.tpsCount, 2)
    }

    func testAccumulateRequestIgnoresAllNil() {
        let store = StatsStore.shared
        store.accumulateRequest(ttft: nil, tps: nil)
        XCTAssertNil(store.today.avgTTFT)
        XCTAssertNil(store.today.avgTokPerSecond)
        XCTAssertEqual(store.today.ttftCount, 0)
        XCTAssertEqual(store.today.tpsCount, 0)
    }

    func testP95TTFTNeedsTwoSamples() {
        let store = StatsStore.shared
        store.accumulateRequest(ttft: 0.5, tps: nil)
        // Single sample: p95 falls back to the mean.
        XCTAssertEqual(store.today.p95TTFT!, 0.5, accuracy: 0.001)
        store.accumulateRequest(ttft: 0.7, tps: nil)
        // Two samples: p95 > mean.
        XCTAssertGreaterThanOrEqual(store.today.p95TTFT!, 0.6)
    }

    func testPersistenceAcrossReload() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 3, output: 400, serverPort: 8081)
        store.accumulateRequest(ttft: 0.35, tps: 65.0)
        let fresh = StatsStore()
        let after = fresh.today
        XCTAssertEqual(after.baselineCompleted, 3)
        XCTAssertEqual(after.baselineOutputTokens, 400)
        XCTAssertEqual(after.completedToday(current: 7), 4)
        XCTAssertEqual(after.outputToday(current: 1000), 600)
        XCTAssertEqual(after.avgTTFT!, 0.35, accuracy: 0.001)
        XCTAssertEqual(after.avgTokPerSecond!, 65.0, accuracy: 0.001)
    }

    func testDailyRolloverStartsFreshDay() {
        let store = StatsStore.shared
        store.updateBaselines(completed: 5, output: 500, serverPort: 8081)
        store.accumulateRequest(ttft: 0.4, tps: 50.0)
        // Force a date rollover by mutating the persisted day.
        var s = store.today
        s.date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
        // Write it back by simulating a save of the stale day.
        StatsStore.save(s)
        // A fresh store on a new day starts clean.
        let fresh = StatsStore()
        XCTAssertNil(fresh.today.baselineCompleted)
        XCTAssertEqual(fresh.today.ttftCount, 0)
    }
}
