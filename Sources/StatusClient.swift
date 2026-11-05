import Foundation

/// Subset of the `GET /status` JSON (schema_version 6) used by the UI.
struct StatusDoc: Decodable {
    let ready: Bool?
    let thermal_state: String?
    let maximum_context_tokens: Int?
    let memory_pressure: String?
    let requests: Requests?
    let metrics: Metrics?
    let cache: Cache?
    let scheduler: Scheduler?
    let instance: Instance?
    let transport: Transport?
    let memory_current_bytes: Int?
    let memory_actual: MemoryActual?
    let metal: Metal?
    let weights: Weights?
    let active_requests: [ActiveRequest]?
    let admission: Admission?
    let kv: KV?
    let disk: Disk?
    let loop: Loop?
    let ane_ffn: ANEFFN?
    let input_modalities: [String]?

    /// `memory_actual` since schema 6; older builds report a top-level
    /// `memory_current_bytes` instead.
    struct MemoryActual: Decodable {
        let allocated_bytes: Int?
        let current_bytes: Int?
        let peak_bytes: Int?
    }

    struct Metal: Decodable {
        let healthy: Bool?
        let failure_reason: String?
    }

    struct ActiveRequest: Decodable {
        let id: Int?
        let phase: String?
        let prompt_tokens: Int?
        let prompt_processed: Int?
        let generated_tokens: Int?
        let max_new_tokens: Int?
        let age_ms: Double?
    }

    struct Requests: Decodable {
        let submitted: Int?
        let completed: Int?
        let cancelled: Int?
        let failed: Int?
    }

    struct Metrics: Decodable {
        let ttft_ms: Percentiles?
        /// Inter-token latency in ms, across all generated tokens.
        let itl_ms: Percentiles?
        let prefill_tokens_per_second: Double?
        let decode_tokens_per_second: Double?
        let decode_output_tokens: Int?
        /// Speculative decoding, since the server started: tokens the draft
        /// model proposed, of how many the main model accepted.
        let drafted_tokens: Int?
        let accepted_draft_tokens: Int?
        let draft_acceptance_rate: Double?
        let current_decode_batch: Batch?
        let current_prefill_batch: Batch?
        /// Engine-side failure counters; non-zero means requests have been
        /// dropped or Metal calls have failed since the server started.
        let metal_failures: Int?
        let capacity_failures: Int?

        struct Percentiles: Decodable {
            let p50: Double?
            let p95: Double?
        }

        struct Batch: Decodable {
            let valid: Bool?
            let tokens_per_second: Double?
            let input_tokens: Int?
            let output_tokens: Int?
        }
    }

    struct Cache: Decodable {
        let hit_rate: Double?
        let reused_tokens: Int?
        /// Prompt tokens served from the KV cache instead of re-prefilled,
        /// since the server started.
        let kv_hit_tokens: Int?
        let deduplicated_kv_tokens: Int?
    }

    struct Scheduler: Decodable {
        let prefilling: Int?
        let decoding: Int?
        let queued: Int?
        /// Queued requests blocked on memory/attention budget.
        let waiting_resources: Int?
    }

    struct Instance: Decodable {
        let pid: Int?
        let started_at: Double?
        let model: String?
        let port: Int?
    }

    struct Transport: Decodable {
        let ready: Bool?
        let stopped: Bool?
        /// True while the `serve-native` engine is restarting after a crash;
        /// requests can't be served during that window.
        let recovering: Bool?
        /// Engine restarts since the server started.
        let restarts: Int?
        /// Trace of the most recent engine crash, if any.
        let last_crash_trace: String?
        /// How old the server's own status snapshot is (ms; ~0 while its
        /// event loop is responsive).
        let status_age_ms: Double?
    }

    struct Weights: Decodable {
        let released: Bool?
        let restoring: Bool?
        /// Idle seconds after which splash releases the weights from memory.
        let idle_release_seconds: Double?
        let restores: Int?
        let restore_failures: Int?
    }

    /// Queue admission: how long the oldest waiting request has waited.
    struct Admission: Decodable {
        let oldest_wait_ms: Double?
    }

    /// KV (key/value) cache held in server memory for prompt context.
    struct KV: Decodable {
        let allocated_bytes: Int?
    }

    /// Persistent disk cache (Settings: --max-cache-disk / --persistent-cache).
    struct Disk: Decodable {
        let used_bytes: Int?
        let limit_bytes: Int?
        /// True while splash is pausing cache writes (budget or disk).
        let writes_gated: FlexBool?
    }

    /// Server event-loop health, self-reported.
    struct Loop: Decodable {
        let max_tick_ms: Double?
    }

    /// How the model's FFN layers split between the Apple Neural Engine and
    /// the GPU: state is ane / split / gpu, share is the ANE's fraction.
    struct ANEFFN: Decodable {
        let state: String?
        let share: Double?
    }
}

/// A JSON field that may be a bool or a yes/no-style string (splash's
/// `disk.writes_gated` is a string in schema 6). Lenient: anything
/// unrecognized counts as false rather than failing the whole document.
struct FlexBool: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else {
            value = false
            return
        }
        if let b = try? c.decode(Bool.self) {
            value = b
        } else if let s = try? c.decode(String.self) {
            value = ["yes", "true", "on"].contains(s.lowercased())
        } else {
            value = false
        }
    }
}

enum StatusClient {
    /// What answers (if anything) on the port: a splash server (with its
    /// status), some other HTTP service, or nothing.
    enum Probe {
        case splash(StatusDoc)
        case other
        case nothing
    }

    /// A session that goes straight to 127.0.0.1. Every URLSession (including
    /// `URLSession.shared`) resolves the system's proxy settings before it
    /// connects, and some PAC configs route loopback through a proxy — which
    /// would break (or leak) the local poll. macOS has no per-session "no
    /// proxy" setting, so loopback requests are claimed by
    /// `DirectLoopbackProtocol`, which opens the TCP connection itself and
    /// never lets the session's proxy resolution run.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectLoopbackProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    /// Probe `/status` on the local port and classify the answer.
    static func probe(port: Int, timeout: TimeInterval = 5) async -> Probe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/status") else { return .nothing }
        let request = URLRequest(url: url, timeoutInterval: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .nothing }
            guard http.statusCode == 200,
                  let doc = try? JSONDecoder().decode(StatusDoc.self, from: data),
                  isSplash(doc, port: port)
            else {
                // The port connects and answers — just not with splash's
                // status: something else is serving it.
                return .other
            }
            return .splash(doc)
        } catch {
            // Connection refused / timeout: nothing is listening.
            return .nothing
        }
    }

    /// Fetch and decode `/status` from the local server. Returns nil on a
    /// timeout, an error, or a reply that isn't splash's: another service on
    /// the port must not be mistaken for an "external" splash server.
    static func fetch(port: Int, timeout: TimeInterval = 5) async -> StatusDoc? {
        switch await probe(port: port, timeout: timeout) {
        case .splash(let doc): return doc
        default: return nil
        }
    }

    /// splash's /status always has an `instance` block naming the server's
    /// pid and port, and a `ready` flag.
    private static func isSplash(_ doc: StatusDoc, port: Int) -> Bool {
        guard let instance = doc.instance, doc.ready != nil,
              instance.pid != nil || instance.model != nil else { return false }
        return instance.port == nil || instance.port == port
    }
}

/// Serves HTTP requests to 127.0.0.1 over a direct TCP connection, replacing
/// the session's connection machinery (and with it the system proxy
/// resolution) for those requests. Only the simple GETs the app makes are
/// implemented: the request is sent with "Connection: close" and the
/// response is read until EOF, so no chunked-transfer parsing is needed.
final class DirectLoopbackProtocol: URLProtocol {
    /// The session cancels the load (e.g. the caller's task is released);
    /// stop the background read from delivering callbacks afterwards.
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {
        stopped = true
    }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let port = url.port ?? 80
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 5
        let line = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nAccept: */*\r\n\r\n"
        DispatchQueue.global(qos: .userInitiated).async {
            self.run(line: line, port: port, timeout: timeout, client: client)
        }
    }

    private func run(line: String, port: Int, timeout: TimeInterval,
                     client: URLProtocolClient) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail(client, .cannotConnectToHost) }
        defer { close(fd) }

        // Send and receive time out, so a stalled connection can't hang the
        // poll (the caller probes with its own short timeout).
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else {
            return fail(client, .badURL)
        }
        let rc: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return fail(client, .cannotConnectToHost) }

        let bytes = Array(line.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            guard n > 0 else { return fail(client, .networkConnectionLost) }
            sent += n
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        let chunk = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, chunk)
            }
            if n == 0 { break }                       // EOF: "Connection: close"
            if n < 0 {
                let e = errno
                return fail(client, e == EAGAIN || e == EWOULDBLOCK
                            ? .timedOut : .networkConnectionLost)
            }
            data.append(contentsOf: buf[0..<n])
        }

        deliver(data, port: port, client: client)
    }

    private func deliver(_ data: Data, port: Int, client: URLProtocolClient) {
        guard !stopped else { return }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return fail(client, .badServerResponse)
        }
        let head = String(decoding: data.subdata(in: 0..<sep.lowerBound), as: UTF8.self)
        let body = data.subdata(in: sep.upperBound..<data.endIndex)
        let status = head.split(separator: "\r\n").first
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .flatMap { Int($0) }
        guard let code = status,
              let url = URL(string: "http://127.0.0.1:\(port)"),
              let response = HTTPURLResponse(url: url, statusCode: code,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: nil) else {
            return fail(client, .badServerResponse)
        }
        client.urlProtocol(self, didReceive: response,
                           cacheStoragePolicy: .allowed)
        if !body.isEmpty {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ client: URLProtocolClient, _ code: URLError.Code) {
        guard !stopped else { return }
        client.urlProtocol(self, didFailWithError: URLError(code))
    }
}
