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
}
