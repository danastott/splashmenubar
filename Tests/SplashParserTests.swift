import XCTest
@testable import SplashMenuBar

/// Fixtures for the line formats `splash serve` actually prints. The middle
/// dot and arrow are U+00B7 / U+2192, exactly as splash emits them.
final class SplashParserTests: XCTestCase {
    func testDoneLine() {
        let line = "12:00:01 req 7 Done \u{B7} input 1200 \u{B7} cached 800 \u{B7} deduplicated 12 \u{B7} output 512 \u{B7} TTFT 0.31s \u{B7} 58.9 tok/s \u{B7} 2.1 tok/cycle"
        guard case let .request(r) = SplashParser.parse(line) else {
            return XCTFail("expected .request")
        }
        XCTAssertFalse(r.isStarted)
        XCTAssertEqual(r.input, 1200)
        XCTAssertEqual(r.cached, 800)
        XCTAssertEqual(r.deduplicated, 12)
        XCTAssertEqual(r.output, 512)
        guard let ttft = r.ttftSeconds, let tps = r.tokensPerSecond,
              let tpc = r.tokensPerCycle else {
            return XCTFail("missing ttft/tps/tpc")
        }
        XCTAssertEqual(ttft, 0.31, accuracy: 0.001)
        XCTAssertEqual(tps, 58.9, accuracy: 0.001)
        XCTAssertEqual(tpc, 2.1, accuracy: 0.001)
    }

    func testDoneLineWithoutExtras() {
        guard case let .request(r) = SplashParser.parse("12:00:01 req 7 Done") else {
            return XCTFail("expected .request")
        }
        XCTAssertFalse(r.isStarted)
        XCTAssertNil(r.output)
        XCTAssertNil(r.tokensPerSecond)
    }

    func testStartedLine() {
        guard case let .request(r) = SplashParser.parse("12:00:00 req 7 Started") else {
            return XCTFail("expected .request")
        }
        XCTAssertTrue(r.isStarted)
        XCTAssertNil(r.input)
    }

    func testFetchingLine() {
        guard case let .fetching(repo, files, bytes?) = SplashParser.parse(
            "Fetching 3 file(s), 16.50 GB, from owner/repo@abc123; using xet") else {
            return XCTFail("expected .fetching")
        }
        XCTAssertEqual(repo, "owner/repo")
        XCTAssertEqual(files, 3)
        XCTAssertEqual(bytes, 16.5e9, accuracy: 1e3)
    }

    func testXetByteBar() {
        guard case let .progress(bar) = SplashParser.parse(
            "Reconstructing (xet):  42%|####    |  6.93GB / 16.5GB,  52.1MB/s") else {
            return XCTFail("expected .progress")
        }
        XCTAssertEqual(bar.fraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(bar.label, "Reconstructing (xet)")
        XCTAssertEqual(bar.done, "6.93GB")
        XCTAssertEqual(bar.total, "16.5GB")
        XCTAssertEqual(bar.rate, "52.1MB/s")
        XCTAssertTrue(bar.isBytes)
        XCTAssertNotNil(bar.eta)
    }

    func testClassicTqdmBar() {
        guard case let .progress(bar) = SplashParser.parse(
            "model.gguf:  42%|####    | 6.93G/16.5G [02:10<03:00, 52.1MB/s]") else {
            return XCTFail("expected .progress")
        }
        XCTAssertEqual(bar.fraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(bar.label, "model.gguf")
        XCTAssertEqual(bar.done, "6.93GB")
        XCTAssertEqual(bar.total, "16.5GB")
        XCTAssertEqual(bar.eta, "03:00")
        XCTAssertEqual(bar.rate, "52.1MB/s")
        XCTAssertTrue(bar.isBytes)
    }

    func testFileCountBarIsNotBytes() {
        guard case let .progress(bar) = SplashParser.parse(
            "Fetching 3 files: 33%|#     | 1/3 [00:05<00:10, 1.2file/s]") else {
            return XCTFail("expected .progress")
        }
        XCTAssertEqual(bar.done, "1")
        XCTAssertEqual(bar.total, "3")
        XCTAssertFalse(bar.isBytes)
    }

    func testJsonDownloadLine() {
        guard case let .progress(bar) = SplashParser.parse(
            #"{"event": "download", "repo": "owner/repo", "done": 5000, "total": 20000}"#) else {
            return XCTFail("expected .progress")
        }
        XCTAssertEqual(bar.fraction, 0.25, accuracy: 0.001)
        // Display string comes from the app's own formatter (locale-dependent).
        XCTAssertEqual(bar.done, SplashParser.decimalBytes(5000))
        XCTAssertEqual(bar.total, SplashParser.decimalBytes(20000))
        XCTAssertTrue(bar.isBytes)
    }

    func testReadyLine() {
        guard case let .ready(model, context, url) = SplashParser.parse(
            "14:22:03 Ready \u{B7} owner/repo \u{B7} context 256K \u{B7} http://127.0.0.1:8081") else {
            return XCTFail("expected .ready")
        }
        XCTAssertEqual(model, "owner/repo")
        XCTAssertEqual(context, "256K")
        XCTAssertEqual(url, "http://127.0.0.1:8081")
    }

    func testThermalTransition() {
        guard case let .thermal(from, to) = SplashParser.parse(
            "Thermal state: nominal \u{2192} fair") else {
            return XCTFail("expected .thermal")
        }
        XCTAssertEqual(from, "nominal")
        XCTAssertEqual(to, "fair")
    }

    func testWeightsLoaded() {
        guard case let .weightsLoaded(s) = SplashParser.parse("Weights loaded in 3.08 s.") else {
            return XCTFail("expected .weightsLoaded")
        }
        XCTAssertEqual(s, 3.08, accuracy: 0.001)
    }

    func testSelectedLine() {
        guard case let .selected(file, repo) = SplashParser.parse(
            "Selected /models/owner/repo/Qwen3.8-27B-UD-Q4_K_M.gguf from owner/repo.") else {
            return XCTFail("expected .selected")
        }
        XCTAssertEqual(file, "/models/owner/repo/Qwen3.8-27B-UD-Q4_K_M.gguf")
        XCTAssertEqual(repo, "owner/repo")
    }

    func testLoadingLine() {
        guard case let .loading(model) = SplashParser.parse("Loading \u{B7} owner/repo") else {
            return XCTFail("expected .loading")
        }
        XCTAssertEqual(model, "owner/repo")
    }

    func testUnknownLineIsRaw() {
        guard case .raw = SplashParser.parse("some plain output line") else {
            return XCTFail("expected .raw")
        }
    }

    private func bc(_ s: String) -> Double {
        SplashParser.byteCount(s) ?? -1
    }

    func testByteCount() {
        XCTAssertEqual(bc("6.93GB"), 6.93e9, accuracy: 1e3)
        XCTAssertEqual(bc("6.93G"), 6.93e9, accuracy: 1e3)
        XCTAssertEqual(bc("446kB"), 446_000, accuracy: 1)
        XCTAssertEqual(bc("52.1MB"), 52.1e6, accuracy: 1)
    }
}
