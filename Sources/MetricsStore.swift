import Foundation
import Combine

/// Aggregates parsed splash log lines and polled `/status` endpoint data
/// into publishable metrics state. All mutation happens on the main thread.
final class MetricsStore: ObservableObject {
    // Process state (from SplashProcess).
    @Published var state: SplashState = .stopped {
        didSet {
            // Our child just started: begin tracking its startup.
            if state == .running, oldValue != .running, readyModel == nil {
                startupBegan = Date()
                startupTitle = "Starting splash…"
                startupDetail = nil
                startupFraction = nil
            }
        }
    }

    // Startup progress (from splash's output until it reports Ready).
    @Published var startupTitle: String?
    @Published var startupDetail: String?
    @Published var startupFraction: Double?
    @Published var startupBegan: Date?
    /// Latest plain output line (not a progress redraw), e.g. a warning or
    /// the error splash exited with.
    @Published var lastOutputLine: String?
    private var sawByteProgress = false

    /// Our child is running but not serving yet (preparing, downloading,
    /// loading weights).
    var isStartingUp: Bool {
        (state == .running || state == .starting) && readyModel == nil && !endpointReady
    }

    // Log-derived (per request).
    @Published var requests: [RequestMetrics] = []
    @Published var logLines: [String] = []
    @Published var weightsLoadSeconds: Double?

    // Endpoint-derived (live, from /status).
    @Published var endpointReady = false
    @Published var endpointAlive = false
    /// True when the server on the port is up: our child, or an external
    /// splash process the app did not start.
    var effectiveRunning: Bool {
        if state == .running || state == .starting { return true }
        return endpointAlive
    }
    /// True when the server is up but not our child process.
    var isExternalServer: Bool {
        effectiveRunning && state != .running && state != .starting
    }
    @Published var thermalState: String?
    /// Hottest SoC die sensor, °C (read by the app, not reported by splash).
    @Published var chipTemperatureC: Double?
    /// Whole-machine CPU, GPU and memory use (read by the app, not splash).
    @Published var system = SystemUsage()
    /// The flyout is pinned open (UI state, not from splash).
    @Published var panelPinned = false
    @Published var maxContextTokens: Int?
    @Published var modelFromStatus: String?
    @Published var liveTokensPerSecond: Double?
    @Published var lifetimeTokensPerSecond: Double?
    @Published var prefillTokensPerSecond: Double?
    /// Speed of the prefill batch running now (nil when nothing prefills).
    @Published var livePrefillTokensPerSecond: Double?
    @Published var cacheHitRate: Double?
    @Published var ttftP50: Double?
    @Published var ttftP95: Double?
    @Published var completedCount: Int?
    @Published var failedCount: Int?
    @Published var cancelledCount: Int?
    @Published var decodingCount: Int?
    @Published var prefillingCount: Int?
    @Published var queuedCount: Int?
    @Published var totalOutputTokens: Int?
    @Published var memoryUsedBytes: Int?
    @Published var serverStartedAt: Date?
    @Published var weightsReleased = false
    @Published var tpsHistory: [Double] = []
    @Published var lastPollAt: Date?

    // Prefill progress (from active_requests + prefill rate).
    @Published var prefillFraction: Double?
    @Published var prefillRemainingTokens: Int?
    @Published var prefillETASeconds: Double?

    // Log-derived startup info (fallbacks until the endpoint answers).
    @Published var readyModel: String?
    @Published var readyContext: String?
    @Published var readyURL: String?

    private var nextID = 0

    // MARK: - Gauges

    /// tok/s gauge: live decode batch, else lifetime decode, else last request.
    var gaugeTokensPerSecond: Double? {
        liveTokensPerSecond ?? lifetimeTokensPerSecond ?? last?.tokensPerSecond
    }

    /// cache gauge: endpoint hit rate, else last request's cached/input.
    /// prefill gauge: the prefill running now, else the lifetime average.
    var gaugePrefillTokensPerSecond: Double? {
        livePrefillTokensPerSecond ?? prefillTokensPerSecond
    }

    var gaugeCacheFraction: Double? {
        if let cacheHitRate { return cacheHitRate }
        guard let l = last, let i = l.input, i > 0 else { return nil }
        return Double(l.cached ?? 0) / Double(i)
    }

    var last: RequestMetrics? {
        requests.last { !$0.isStarted }
    }

    // MARK: - Log ingest

    func handle(line: String) {
        let event = SplashParser.parse(line)
        // Progress redraws arrive ~10×/s; keep them out of the log.
        switch event {
        case .progress, .ignored: break
        default:
            logLines.append(line)
            if logLines.count > 400 {
                logLines.removeFirst(logLines.count - 400)
            }
        }

        switch event {
        case .ignored:
            break
        case .request(var r):
            nextID += 1
            r.id = nextID
            requests.append(r)
            if requests.count > 2000 {
                requests.removeFirst(requests.count - 2000)
            }
        case .thermal(_, let to):
            thermalState = to
        case .selected(let file, let repo):
            startupTitle = "Preparing \(repo)"
            startupDetail = file
            startupFraction = nil
        case .fetching(let repo, let files, let totalBytes):
            sawByteProgress = false
            startupTitle = "Downloading \(repo)"
            var parts: [String] = []
            if let files { parts.append("\(files) file\(files == 1 ? "" : "s")") }
            if let totalBytes { parts.append(SplashParser.decimalBytes(totalBytes)) }
            startupDetail = parts.isEmpty ? nil : parts.joined(separator: " · ")
            startupFraction = 0
        case .progress(let bar):
            // Byte bars carry size and speed; the file-count bar is only a
            // fallback until (or unless) one appears.
            if bar.isBytes {
                sawByteProgress = true
            } else if sawByteProgress {
                break
            }
            if startupTitle == nil || startupTitle == "Starting splash…" {
                startupTitle = "Downloading model"
            }
            startupFraction = bar.fraction
            var parts = ["\(bar.done) / \(bar.total)"]
            if let r = bar.rate { parts.append(r) }
            if let e = bar.eta { parts.append("\(e) left") }
            startupDetail = parts.joined(separator: " · ")
        case .loading(let model):
            startupTitle = "Loading model weights"
            startupDetail = model
            startupFraction = nil
        case .ready(let model, let context, let url):
            startupTitle = nil
            startupDetail = nil
            startupFraction = nil
            readyModel = model
            readyContext = context
            readyURL = url
            if serverStartedAt == nil { serverStartedAt = Date() }
        case .weightsLoaded(let s):
            weightsLoadSeconds = s
            startupTitle = "Starting the server"
            startupDetail = "Weights loaded in \(Fmt.seconds(s))"
            startupFraction = nil
        case .raw(let text):
            // Drop splash's "HH:MM:SS " prefix; the card shows elapsed time.
            let shown = text.replacingOccurrences(
                of: #"^\d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression)
            if !shown.isEmpty { lastOutputLine = shown }
        }
    }

    // MARK: - Endpoint ingest

    func apply(status doc: StatusDoc) {
        endpointAlive = true
        endpointReady = doc.ready ?? endpointReady
        if let t = doc.thermal_state { thermalState = t }
        maxContextTokens = doc.maximum_context_tokens ?? maxContextTokens
        if let m = doc.instance?.model { modelFromStatus = m }
        if let s = doc.instance?.started_at {
            serverStartedAt = Date(timeIntervalSince1970: s)
        }

        let m = doc.metrics
        lifetimeTokensPerSecond = m?.decode_tokens_per_second
        prefillTokensPerSecond = m?.prefill_tokens_per_second
        ttftP50 = m?.ttft_ms?.p50.map { $0 / 1000 }
        ttftP95 = m?.ttft_ms?.p95.map { $0 / 1000 }
        totalOutputTokens = m?.decode_output_tokens
        // current_decode_batch is the most recent batch and stays "valid"
        // after decoding stops, so it is live only while this poll's
        // scheduler reports a decoding request.
        let batch = m?.current_decode_batch
        let decodingNow = doc.scheduler?.decoding.map { $0 > 0 } ?? true
        if decodingNow, let batch, batch.valid == true, let tps = batch.tokens_per_second, tps > 0 {
            liveTokensPerSecond = tps
        } else {
            liveTokensPerSecond = nil
        }
        // Like the decode batch, the last prefill batch stays "valid" after
        // prefill ends: live only while the scheduler reports prefilling.
        let prefillingNow = doc.scheduler?.prefilling.map { $0 > 0 } ?? false
        if prefillingNow, let b = m?.current_prefill_batch, b.valid == true,
           let tps = b.tokens_per_second, tps > 0 {
            livePrefillTokensPerSecond = tps
        } else {
            livePrefillTokensPerSecond = nil
        }
        // Sample the sparkline from live speed so history tracks the server.
        if let liveTokensPerSecond {
            tpsHistory.append(liveTokensPerSecond)
            // Enough for the graph's longest span at the fastest refresh.
            let cap = SplashConfig.maxGraphSamples
            if tpsHistory.count > cap {
                tpsHistory.removeFirst(tpsHistory.count - cap)
            }
        }

        if let cache = doc.cache {
            if let h = cache.hit_rate { cacheHitRate = h }
        }
        if let r = doc.requests {
            completedCount = r.completed
            failedCount = r.failed
            cancelledCount = r.cancelled
        }
        if let s = doc.scheduler {
            decodingCount = s.decoding
            prefillingCount = s.prefilling
            queuedCount = s.queued
        }
        memoryUsedBytes = doc.memory_current_bytes
        weightsReleased = doc.weights?.released ?? false

        // Prefill progress of the request currently in its prompt phase.
        if let req = doc.active_requests?.first(where: { $0.phase == "prefill" }),
           let total = req.prompt_tokens, total > 0 {
            let processed = min(req.prompt_processed ?? 0, total)
            let remaining = total - processed
            prefillFraction = Double(processed) / Double(total)
            prefillRemainingTokens = remaining
            let rate = doc.metrics?.current_prefill_batch
                .flatMap { $0.valid == true ? $0.tokens_per_second : nil }
                ?? doc.metrics?.prefill_tokens_per_second
            if let rate, rate > 0, remaining > 0 {
                prefillETASeconds = Double(remaining) / rate
            } else {
                prefillETASeconds = nil
            }
        } else {
            prefillFraction = nil
            prefillRemainingTokens = nil
            prefillETASeconds = nil
        }
        lastPollAt = Date()
    }

    func markPollFailed() {
        endpointAlive = false
        livePrefillTokensPerSecond = nil
        prefillFraction = nil
        prefillRemainingTokens = nil
        prefillETASeconds = nil
    }

    func resetForRestart() {
        startupTitle = nil
        startupDetail = nil
        startupFraction = nil
        startupBegan = nil
        lastOutputLine = nil
        sawByteProgress = false
        requests.removeAll()
        logLines.removeAll()
        weightsLoadSeconds = nil
        readyModel = nil
        readyContext = nil
        readyURL = nil
        endpointReady = false
        endpointAlive = false
        prefillFraction = nil
        prefillRemainingTokens = nil
        prefillETASeconds = nil
        thermalState = nil
        maxContextTokens = nil
        modelFromStatus = nil
        liveTokensPerSecond = nil
        lifetimeTokensPerSecond = nil
        prefillTokensPerSecond = nil
        livePrefillTokensPerSecond = nil
        cacheHitRate = nil
        ttftP50 = nil
        ttftP95 = nil
        completedCount = nil
        failedCount = nil
        cancelledCount = nil
        decodingCount = nil
        prefillingCount = nil
        queuedCount = nil
        totalOutputTokens = nil
        memoryUsedBytes = nil
        serverStartedAt = nil
        weightsReleased = false
        tpsHistory.removeAll()
        lastPollAt = nil
    }
}

// MARK: - Formatting

enum Fmt {
    static func int(_ v: Int?) -> String {
        v.map { $0.formatted() } ?? "—"
    }

    static func double(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    static func seconds(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return (v * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func bytes(_ v: Int?) -> String {
        guard let v else { return "—" }
        let gib = Double(v) / 1_073_741_824
        return gib.formatted(.number.precision(.fractionLength(1))) + " GiB"
    }

    static func context(_ tokens: Int?) -> String {
        guard let tokens else { return "—" }
        if tokens >= 1000 {
            return (Double(tokens) / 1000).formatted(.number.precision(.fractionLength(tokens % 1000 == 0 ? 0 : 1))) + "K"
        }
        return tokens.formatted()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }
}
