import XCTest
@testable import SplashMenuBar

/// The no-progress (stuck) detection in MetricsStore: driven by
/// `evaluateStuck(doc:now:)` on every successful /status poll and by
/// `markPollFailed()` when the server stops answering.
final class MetricsStoreTests: XCTestCase {

    private func makeStore(threshold: TimeInterval = 0.05) -> MetricsStore {
        let s = MetricsStore()
        s.stuckThreshold = threshold
        return s
    }

    /// A document with one in-flight request; `progress` fills
    /// prompt_processed (prefill) or generated_tokens (decode).
    private func activeDoc(progress: Int, phase: String = "decode") -> StatusDoc {
        let field = phase == "prefill"
            ? "\"prompt_tokens\": 1000, \"prompt_processed\": \(progress)"
            : "\"generated_tokens\": \(progress)"
        let scheduler = phase == "prefill"
            ? "{\"prefilling\": 1, \"decoding\": 0, \"queued\": 0}"
            : "{\"prefilling\": 0, \"decoding\": 1, \"queued\": 0}"
        let json = """
        {"ready": true,
         "instance": {"model": "m"},
         "scheduler": \(scheduler),
         "active_requests": [{"id": 1, "phase": "\(phase)", \(field)}]}
        """
        return try! JSONDecoder().decode(StatusDoc.self, from: json.data(using: .utf8)!)
    }

    private func idleDoc() -> StatusDoc {
        let json = """
        {"ready": true,
         "instance": {"model": "m"},
         "scheduler": {"prefilling": 0, "decoding": 0, "queued": 0},
         "active_requests": []}
        """
        return try! JSONDecoder().decode(StatusDoc.self, from: json.data(using: .utf8)!)
    }

    func testIdleClearsStuckState() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.markPollFailed()
        XCTAssertTrue(store.requestStuck)
        store.evaluateStuck(doc: idleDoc(), now: Date())
        XCTAssertFalse(store.requestStuck)
        // The clock is gone too: a fresh in-flight request starts clean.
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 0), now: Date())
        XCTAssertFalse(store.requestStuck)
    }

    func testProgressingRequestNeverSticks() {
        let store = makeStore()
        var progress = 100
        for _ in 0..<6 {
            store.evaluateStuck(doc: activeDoc(progress: progress), now: Date())
            Thread.sleep(forTimeInterval: 0.06)   // past the threshold each round
            progress += 40
        }
        XCTAssertFalse(store.requestStuck)
    }

    func testNoProgressBecomesStuck() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertTrue(store.requestStuck)
        // A further stagnant poll keeps it stuck (no re-firing churn).
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertTrue(store.requestStuck)
    }

    func testProgressResumingClearsStuck() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertTrue(store.requestStuck)
        store.evaluateStuck(doc: activeDoc(progress: 140), now: Date())
        XCTAssertFalse(store.requestStuck)
    }

    func testTurnoverResetsClock() {
        let store = makeStore()
        // A long request finishes; a fresh one starts with a low counter.
        store.evaluateStuck(doc: activeDoc(progress: 500), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 10), now: Date())
        XCTAssertFalse(store.requestStuck)
        // The fresh request's clock starts at the turnover, not before.
        store.evaluateStuck(doc: activeDoc(progress: 10), now: Date())
        XCTAssertFalse(store.requestStuck)
    }

    func testWeightsRestoringHoldsClockWithoutFiring() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        store.weightsRestoring = true
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertFalse(store.requestStuck)   // held, not fired
        store.weightsRestoring = false
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertFalse(store.requestStuck)   // clock restarted by the hold
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        XCTAssertTrue(store.requestStuck)    // and it can still fire after
    }

    func testPollFailureCanStuck() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        // The server stops answering: no apply(), the failure path fires.
        store.markPollFailed()
        store.markPollFailed()
        XCTAssertTrue(store.requestStuck)
    }

    func testQueuedOnlyRequestCanStuck() {
        let store = makeStore()
        let json = """
        {"ready": true,
         "instance": {"model": "m"},
         "scheduler": {"prefilling": 0, "decoding": 0, "queued": 1},
         "active_requests": [{"id": 1, "phase": "queued"}]}
        """
        let doc = try! JSONDecoder().decode(StatusDoc.self, from: json.data(using: .utf8)!)
        store.evaluateStuck(doc: doc, now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.evaluateStuck(doc: doc, now: Date())
        XCTAssertTrue(store.requestStuck)
    }

    func testInFlightProgressSumsPhases() {
        let json = """
        {"ready": true,
         "instance": {"model": "m"},
         "scheduler": {"prefilling": 1, "decoding": 1, "queued": 1},
         "active_requests": [
            {"id": 1, "phase": "prefill", "prompt_processed": 300},
            {"id": 2, "phase": "decode", "generated_tokens": 120},
            {"id": 3, "phase": "queued"}]}
        """
        let doc = try! JSONDecoder().decode(StatusDoc.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(MetricsStore.inFlightProgress(from: doc), 420)
    }

    func testResetForRestartClearsStuck() {
        let store = makeStore()
        store.evaluateStuck(doc: activeDoc(progress: 100), now: Date())
        Thread.sleep(forTimeInterval: 0.06)
        store.markPollFailed()
        XCTAssertTrue(store.requestStuck)
        store.resetForRestart()
        XCTAssertFalse(store.requestStuck)
    }

    // MARK: - Request-finished notification threshold

    private func doneRequest(output: Int?, tps: Double?, ttft: Double? = nil) -> RequestMetrics {
        RequestMetrics(id: 1, isStarted: false, timestamp: Date(),
                       input: 100, cached: nil, deduplicated: nil,
                       output: output, ttftSeconds: ttft,
                       tokensPerSecond: tps, tokensPerCycle: nil)
    }

    /// Runs `body` with the daily-stats file redirected to a temp directory,
    /// so the log ingest below never touches the real TODAY stats.
    private func withIsolatedStats(_ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashmenubar-stats-\(UUID().uuidString)", isDirectory: true)
        StatsStore.statsURLOverride = dir.appendingPathComponent("stats.json")
        StatsStore.shared.resetForTesting()
        defer {
            StatsStore.statsURLOverride = nil
            StatsStore.shared.resetForTesting()
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    func testRequestSecondsIsTTFTPlusDecode() {
        // splash's Done line reports TTFT separately from the decode speed,
        // so the wall-clock estimate is TTFT + output ÷ speed.
        XCTAssertEqual(doneRequest(output: 2000, tps: 80).requestSeconds, 25)
        XCTAssertEqual(doneRequest(output: 206, tps: 74.4, ttft: 43).requestSeconds!,
                       43 + 206 / 74.4, accuracy: 0.001)
        XCTAssertTrue(doneRequest(output: 2000, tps: 80).worthNotifying)
    }

    func testLongPrefillWithShortAnswerNotifies() {
        // A cold long prompt that answered briefly still ran ~46 s: the
        // decode time alone (2.8 s) must not keep it silent.
        let cold = doneRequest(output: 206, tps: 74.4, ttft: 43)
        XCTAssertTrue(cold.worthNotifying)
        // A Done line with only a TTFT still gives a lower bound.
        XCTAssertEqual(doneRequest(output: nil, tps: nil, ttft: 12).requestSeconds, 12)
        XCTAssertTrue(doneRequest(output: nil, tps: nil, ttft: 12).worthNotifying)
    }

    func testShortRequestNotWorthNotifying() {
        XCTAssertEqual(doneRequest(output: 200, tps: 100).requestSeconds, 2)
        XCTAssertFalse(doneRequest(output: 200, tps: 100).worthNotifying)
        XCTAssertFalse(doneRequest(output: 200, tps: 100, ttft: 1).worthNotifying)
        // Exactly the threshold still notifies.
        XCTAssertTrue(doneRequest(output: 100, tps: 10).worthNotifying)
    }

    func testUntimableRequestNotWorthNotifying() {
        // No speed, output or TTFT in the Done line: the duration can't be
        // estimated, so the request stays silent instead of guessing.
        XCTAssertFalse(doneRequest(output: 200, tps: nil).worthNotifying)
        XCTAssertFalse(doneRequest(output: nil, tps: 100).worthNotifying)
        XCTAssertFalse(doneRequest(output: 200, tps: 0).worthNotifying)
    }

    func testHandleDoneLineEmitsFinishedRequest() {
        withIsolatedStats {
            let store = makeStore()
            var finished: [RequestMetrics] = []
            let sub = store.requestFinished.sink { finished.append($0) }
            defer { sub.cancel() }
            store.handle(line: "12:00:01 req 7 Started")
            XCTAssertTrue(finished.isEmpty, "a Started line is not a completion")
            store.handle(line: "12:00:30 req 7 Done · input 1200 · output 2000 · TTFT 0.31s · 80 tok/s")
            XCTAssertEqual(finished.count, 1)
            XCTAssertEqual(finished[0].output, 2000)
            XCTAssertTrue(finished[0].worthNotifying)
        }
    }
}
