import XCTest
@testable import SplashMenuBar

/// Decode contract for the schema-6 /status fields the UI displays: a field
/// name typo must fail here, not silently render "—" next to a live server.
final class StatusClientTests: XCTestCase {
    /// A /status carrying every block StatusDoc decodes, in the shapes the
    /// live splash 1.5.0 server reports.
    private let docJSON = """
    {
      "ready": true,
      "thermal_state": "fair",
      "maximum_context_tokens": 262144,
      "memory_pressure": "normal",
      "input_modalities": ["text", "image", "pdf"],
      "instance": {"pid": 1, "model": "m", "port": 8081, "started_at": 1700000000},
      "requests": {"submitted": 5, "completed": 4, "cancelled": 0, "failed": 1},
      "metrics": {
        "ttft_ms": {"p50": 1000, "p95": 2000},
        "itl_ms": {"p50": 16.5, "p95": 66.5},
        "prefill_tokens_per_second": 310,
        "decode_tokens_per_second": 67,
        "decode_output_tokens": 1854,
        "drafted_tokens": 24521,
        "accepted_draft_tokens": 8848,
        "draft_acceptance_rate": 0.36,
        "metal_failures": 0,
        "capacity_failures": 0,
        "current_decode_batch": {"valid": true, "tokens_per_second": 108, "input_tokens": 0, "output_tokens": 7}
      },
      "cache": {"hit_rate": 0.75, "reused_tokens": 103520, "kv_hit_tokens": 321984, "deduplicated_kv_tokens": 3872},
      "scheduler": {"prefilling": 0, "decoding": 2, "queued": 3, "waiting_resources": 1},
      "admission": {"oldest_wait_ms": 12000},
      "kv": {"allocated_bytes": 817889280},
      "disk": {"used_bytes": 2254857830, "limit_bytes": 34359738368, "writes_gated": "no"},
      "loop": {"max_tick_ms": 99.3},
      "ane_ffn": {"state": "split", "share": 0.558},
      "memory_actual": {"allocated_bytes": 1, "current_bytes": 22638821376, "peak_bytes": 22638821376},
      "metal": {"healthy": true},
      "weights": {"released": false, "restoring": false, "idle_release_seconds": 600, "restores": 2, "restore_failures": 0},
      "transport": {"ready": true, "stopped": false, "recovering": false, "restarts": 0, "status_age_ms": 42},
      "active_requests": [
        {"id": 1, "phase": "prefill", "prompt_tokens": 1000, "prompt_processed": 250},
        {"id": 2, "phase": "decode", "generated_tokens": 240, "max_new_tokens": 1024, "age_ms": 45000}
      ]
    }
    """

    private func decode(_ json: String) throws -> StatusDoc {
        try JSONDecoder().decode(StatusDoc.self, from: json.data(using: .utf8)!)
    }

    func testDecodeSchema6Fields() throws {
        let d = try decode(docJSON)
        XCTAssertEqual(d.input_modalities, ["text", "image", "pdf"])
        XCTAssertEqual(d.metrics?.itl_ms?.p50, 16.5)
        XCTAssertEqual(d.metrics?.itl_ms?.p95, 66.5)
        XCTAssertEqual(d.metrics?.drafted_tokens, 24521)
        XCTAssertEqual(d.metrics?.accepted_draft_tokens, 8848)
        XCTAssertEqual(d.metrics?.draft_acceptance_rate, 0.36)
        XCTAssertEqual(d.cache?.kv_hit_tokens, 321984)
        XCTAssertEqual(d.scheduler?.waiting_resources, 1)
        XCTAssertEqual(d.admission?.oldest_wait_ms, 12000)
        XCTAssertEqual(d.kv?.allocated_bytes, 817889280)
        XCTAssertEqual(d.disk?.used_bytes, 2254857830)
        XCTAssertEqual(d.disk?.limit_bytes, 34359738368)
        XCTAssertEqual(d.disk?.writes_gated?.value, false)
        XCTAssertEqual(d.loop?.max_tick_ms, 99.3)
        XCTAssertEqual(d.ane_ffn?.state, "split")
        XCTAssertEqual(d.ane_ffn?.share, 0.558)
        XCTAssertEqual(d.weights?.idle_release_seconds, 600)
        XCTAssertEqual(d.weights?.restores, 2)
        XCTAssertEqual(d.transport?.status_age_ms, 42)
        let decode = d.active_requests?.first { $0.phase == "decode" }
        XCTAssertEqual(decode?.generated_tokens, 240)
        XCTAssertEqual(decode?.max_new_tokens, 1024)
        XCTAssertEqual(decode?.age_ms, 45000)
    }

    func testFlexBoolAcceptsStringAndBool() throws {
        let yes = try decode(#"{"disk":{"writes_gated":"yes"}}"#)
        XCTAssertEqual(yes.disk?.writes_gated?.value, true)
        let bool = try decode(#"{"disk":{"writes_gated":true}}"#)
        XCTAssertEqual(bool.disk?.writes_gated?.value, true)
        let no = try decode(#"{"disk":{"writes_gated":"no"}}"#)
        XCTAssertEqual(no.disk?.writes_gated?.value, false)
        let absent = try decode(#"{}"#)
        XCTAssertNil(absent.disk?.writes_gated)
        // Neither a bool nor a string must fail the document.
        let odd = try decode(#"{"disk":{"writes_gated":3}}"#)
        XCTAssertEqual(odd.disk?.writes_gated?.value, false)
    }

    func testApplyIngestsNewFields() throws {
        let store = MetricsStore()
        store.apply(status: try decode(docJSON))
        XCTAssertEqual(store.itlP50, 16.5)
        XCTAssertEqual(store.itlP95, 66.5)
        XCTAssertEqual(store.draftAcceptance, 0.36)
        XCTAssertEqual(store.draftedTokens, 24521)
        XCTAssertEqual(store.kvHitTokens, 321984)
        XCTAssertEqual(store.kvAllocatedBytes, 817889280)
        XCTAssertEqual(store.oldestWaitMs, 12000)
        XCTAssertEqual(store.waitingResources, 1)
        XCTAssertEqual(store.diskUsedBytes, 2254857830)
        XCTAssertEqual(store.diskLimitBytes, 34359738368)
        XCTAssertEqual(store.diskWritesGated, false)
        XCTAssertEqual(store.weightsIdleReleaseSeconds, 600)
        XCTAssertEqual(store.weightsRestores, 2)
        XCTAssertEqual(store.inputModalities, ["text", "image", "pdf"])
        XCTAssertEqual(store.aneState, "split")
        XCTAssertEqual(store.aneShare, 0.558)
        XCTAssertEqual(store.statusAgeMs, 42)
        XCTAssertEqual(store.maxTickMs, 99.3)
        XCTAssertEqual(store.decodeGeneratedTokens, 240)
        XCTAssertEqual(store.decodeMaxTokens, 1024)
        XCTAssertEqual(store.decodeAgeSeconds, 45)
    }

    func testDraftAcceptanceFallsBackToCounts() {
        let store = MetricsStore()
        let json = #"{"ready":true,"metrics":{"drafted_tokens":10,"accepted_draft_tokens":4}}"#
        store.apply(status: try! decode(json))
        guard let acc = store.draftAcceptance else {
            return XCTFail("expected draft acceptance 0.4, got nil")
        }
        XCTAssertEqual(acc, 0.4, accuracy: 0.0001)
        // No draft traffic: acceptance stays nil, the row reads "off".
        let store2 = MetricsStore()
        store2.apply(status: try! decode(#"{"ready":true,"metrics":{"drafted_tokens":0}}"#))
        XCTAssertNil(store2.draftAcceptance)
        XCTAssertEqual(store2.draftedTokens, 0)
    }

    /// One slow /status must not blip the dot or drop the in-flight numbers;
    /// the ready/alive flip needs two consecutive failures.
    func testPollFailureNeedsTwoConsecutiveStrikes() throws {
        let store = MetricsStore()
        store.apply(status: try decode(docJSON))
        XCTAssertTrue(store.endpointAlive)

        store.markPollFailed()
        XCTAssertTrue(store.endpointAlive, "one failure must not flip the endpoint")
        XCTAssertNotNil(store.decodeGeneratedTokens,
                        "one failure must not drop in-flight progress")

        store.markPollFailed()
        XCTAssertFalse(store.endpointAlive)
        XCTAssertNil(store.decodeGeneratedTokens)
        XCTAssertNil(store.decodeMaxTokens)
        XCTAssertNil(store.decodeAgeSeconds)

        // A good poll resets the streak: the next single failure is quiet.
        store.apply(status: try decode(docJSON))
        store.markPollFailed()
        XCTAssertTrue(store.endpointAlive)
    }

    // MARK: - Probe (through the direct loopback connection)

    /// A loopback HTTP server running the given body under every path.
    private func startTestServer(port: Int, body: String) throws -> Process {
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashmb-test-\(UUID().uuidString)")
        try body.data(using: .utf8)!.write(to: bodyFile)
        let script = """
        import http.server, os, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(os.environ["BODYFILE"], "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *args): pass
        http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script, String(port)]
        var env = ProcessInfo.processInfo.environment
        env["BODYFILE"] = bodyFile.path
        p.environment = env
        try p.run()
        return p
    }

    /// A free IPv4 loopback port: bind to 0 and take the assigned number.
    private func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = 0
        let bound: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 18099 }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return Int(UInt16(bigEndian: got.sin_port))
    }

    private func waitUntilPortOpens(_ port: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port)).bigEndian
            guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else {
                continue   // can't happen
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// The probe must reach the server over the direct connection and
    /// classify a splash /status as splash.
    func testProbeClassifiesSplashServer() async throws {
        let port = freePort()
        var body = docJSON
        body = body.replacingOccurrences(of: "\"port\": 8081", with: "\"port\": \(port)")
        let server = try startTestServer(port: port, body: body)
        defer { server.terminate() }
        guard waitUntilPortOpens(port) else {
            return XCTFail("test server did not start")
        }
        switch await StatusClient.probe(port: port, timeout: 3) {
        case .splash(let doc):
            XCTAssertEqual(doc.instance?.port, port)
            XCTAssertEqual(doc.metrics?.drafted_tokens, 24521)
        default:
            XCTFail("expected .splash, got a different probe result")
        }
    }

    /// Anything that answers but is not splash's /status classifies as
    /// "other" — both non-JSON and JSON the app doesn't recognize.
    func testProbeClassifiesOtherService() async throws {
        let port = freePort()
        let server = try startTestServer(port: port, body: "<html>not splash</html>")
        defer { server.terminate() }
        guard waitUntilPortOpens(port) else {
            return XCTFail("test server did not start")
        }
        switch await StatusClient.probe(port: port, timeout: 3) {
        case .other: break
        default: XCTFail("expected .other for a non-splash HTTP answer")
        }

        let port2 = freePort()
        let server2 = try startTestServer(port: port2, body: #"{"hello":"world"}"#)
        defer { server2.terminate() }
        guard waitUntilPortOpens(port2) else {
            return XCTFail("test server did not start")
        }
        switch await StatusClient.probe(port: port2, timeout: 3) {
        case .other: break
        default: XCTFail("expected .other for unrecognized JSON")
        }
    }

    /// A port nothing listens on classifies as "nothing".
    func testProbeClassifiesNothing() async {
        let port = freePort()   // closed again by freePort's `defer`
        switch await StatusClient.probe(port: port, timeout: 1) {
        case .nothing: break
        default: XCTFail("expected .nothing for a closed port")
        }
    }
}
