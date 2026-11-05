import Foundation
import Combine
import SwiftUI

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
    /// Set once this startup actually fetched model files from the network;
    /// the app reads (and clears) it when the server reports Ready, so the
    /// "model ready" notification fires for a download, not a plain load.
    var modelDownloadedThisStartup = false
    /// Consecutive-poll count for the raw pressure state, used to confirm a
    /// new value before the displayed `memoryPressure` switches to it.
    private var pressureStreakValue: String?
    private var pressureStreak = 0

    /// Our child is running but not serving yet (preparing, downloading,
    /// loading weights).
    var isStartingUp: Bool {
        (state == .running || state == .starting) && readyModel == nil && !endpointReady
    }
    /// The status dot is yellow (not green) while splash starts: the rule
    /// both the flyout header and the menu bar use.
    var isStartingStatus: Bool {
        state == .starting || isStartingUp
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
    /// Show the first-launch "pick a model in Settings, then Start" tip
    /// (UI state; cleared on Start, on Save in Settings, or when dismissed).
    @Published var showSetupTip = false
    /// Port of the splash server the app is watching: the configured port,
    /// or that of a splash found running elsewhere (nil = the configured one).
    @Published var serverPort: Int?
    /// User-picked gauge colors by gauge id ("tok", "prefill", "cached",
    /// "gpu", "cpu", "mem", "graph"), as "#RRGGBB" hex — the live copy the
    /// flyout renders from; the app persists it on every change.
    @Published var gaugeColors: [String: String] = [:]
    /// Consecutive failed /status polls: the ready/alive flip waits for two,
    /// so one slow poll can't blip the menu bar's dot to yellow.
    private var pollFailureStreak = 0
    /// True while a service that is NOT splash answers on the configured
    /// port: our child dies with "address in use" and the port is simply
    /// taken.
    @Published var portOccupiedByOther = false
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
    /// Inter-token latency in ms, across all generated tokens.
    @Published var itlP50: Double?
    @Published var itlP95: Double?
    /// Speculative decoding, since startup: share of the draft model's
    /// proposed tokens the main model accepted, and the raw counts.
    @Published var draftAcceptance: Double?
    @Published var draftedTokens: Int?
    @Published var acceptedDraftTokens: Int?
    /// Prompt tokens served from the KV cache instead of re-prefilled.
    @Published var kvHitTokens: Int?
    /// KV cache held in server memory, in bytes.
    @Published var kvAllocatedBytes: Int?
    @Published var completedCount: Int?
    @Published var failedCount: Int?
    @Published var cancelledCount: Int?
    @Published var decodingCount: Int?
    @Published var prefillingCount: Int?
    @Published var queuedCount: Int?
    /// Queued requests blocked on memory/attention budget.
    @Published var waitingResources: Int?
    /// How long the oldest queued request has waited (ms).
    @Published var oldestWaitMs: Double?
    @Published var totalOutputTokens: Int?
    @Published var memoryUsedBytes: Int?
    @Published var memoryPeakBytes: Int?
    @Published var serverStartedAt: Date?
    @Published var weightsReleased = false
    @Published var weightsRestoring = false
    @Published var weightsRestores = 0
    @Published var weightsRestoreFailures = 0
    /// Idle seconds after which the server releases its weights from memory.
    @Published var weightsIdleReleaseSeconds: Double?
    /// Input types the server accepts (text, image, pdf, …).
    @Published var inputModalities: [String] = []
    /// ANE/GPU split of the model's FFN layers: state (ane/split/gpu) and
    /// the ANE's share of the work.
    @Published var aneState: String?
    @Published var aneShare: Double?
    /// Disk (SSD) cache: used/limit bytes, and whether writes are paused.
    @Published var diskUsedBytes: Int?
    @Published var diskLimitBytes: Int?
    @Published var diskWritesGated: Bool?
    /// Server self-report: age of its own status snapshot (ms) and the
    /// longest event-loop tick since startup (ms).
    @Published var statusAgeMs: Double?
    @Published var maxTickMs: Double?
    @Published var tpsHistory: [Double] = []
    @Published var lastPollAt: Date?

    // Engine health (from /status; the app's child can be alive while the
    // serve-native engine under it is not).
    /// The Mac's memory pressure as seen by the server: normal/warning/critical.
    @Published var memoryPressure: String?
    /// True while the engine is restarting after a crash.
    @Published var engineRecovering = false
    /// Engine restarts since the server started.
    @Published var engineRestarts = 0
    /// False only when the server says Metal is unhealthy.
    @Published var metalHealthy: Bool?
    /// Metal + capacity failures since the server started.
    @Published var engineFailures = 0

    // Prefill progress (from active_requests + prefill rate).
    @Published var prefillFraction: Double?
    @Published var prefillRemainingTokens: Int?
    @Published var prefillETASeconds: Double?

    // Decode progress of the request generating now (from active_requests).
    @Published var decodeGeneratedTokens: Int?
    @Published var decodeMaxTokens: Int?
    @Published var decodeAgeSeconds: Double?

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

    /// The CACHED ring shows one semantic only: the server's KV hit rate
    /// since startup (the per-request figure is the "Input / cached" row in
    /// LAST REQUEST, and it doesn't exist for an adopted external server —
    /// /status is the only source that works in both modes).
    var gaugeCacheFraction: Double? {
        cacheHitRate
    }

    /// The flyout's color for a gauge: the user's pick, else the default.
    func gaugeColor(id: String, default: Color) -> Color {
        gaugeColors[id].flatMap { Color(hex: $0) } ?? `default`
    }

    /// A gauge's current color (user's pick, else its default) — what the
    /// color panel opens pre-selected with.
    func currentGaugeColor(id: String) -> Color {
        let def: Color
        switch id {
        case "prefill":         def = .purple
        case "cached":          def = .orange
        case "cpu":             def = .cyan
        case "tok", "graph":    def = .blue
        default:                def = .green   // gpu, mem
        }
        return gaugeColor(id: id, default: def)
    }

    var last: RequestMetrics? {
        requests.last { !$0.isStarted }
    }

    /// The last few plain output lines, for the crash card: a Python
    /// traceback is multi-line and the final line alone rarely says why.
    var crashLines: [String] {
        Array(logLines.suffix(5))
    }

    // MARK: - Log ingest

    func handle(line: String) {
        let event = SplashParser.parse(line)
        // Progress redraws arrive ~10×/s; keep them out of the log.
        switch event {
        case .progress, .ignored: break
        default:
            // Drop splash's "HH:MM:SS " prefix; the crash card shows these
            // lines as-is and the card itself carries the timing.
            let stripped = line.replacingOccurrences(
                of: #"^\d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression)
            if !stripped.isEmpty {
                logLines.append(stripped)
                if logLines.count > 400 {
                    logLines.removeFirst(logLines.count - 400)
                }
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
            modelDownloadedThisStartup = true
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
                modelDownloadedThisStartup = true
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
        pollFailureStreak = 0
        // A splash answering again means the port is splash's, whatever a
        // stale probe said.
        portOccupiedByOther = false
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
        itlP50 = m?.itl_ms?.p50
        itlP95 = m?.itl_ms?.p95
        draftedTokens = m?.drafted_tokens
        acceptedDraftTokens = m?.accepted_draft_tokens
        draftAcceptance = m?.draft_acceptance_rate
            ?? m?.drafted_tokens.flatMap { d in
                d > 0 ? m?.accepted_draft_tokens.map { Double($0) / Double(d) } : nil
            }
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
            kvHitTokens = cache.kv_hit_tokens
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
            waitingResources = s.waiting_resources
        }
        oldestWaitMs = doc.admission?.oldest_wait_ms
        // schema 6 reports memory under `memory_actual`; older builds use a
        // top-level `memory_current_bytes`.
        memoryUsedBytes = doc.memory_actual?.current_bytes ?? doc.memory_current_bytes
        memoryPeakBytes = doc.memory_actual?.peak_bytes
        kvAllocatedBytes = doc.kv?.allocated_bytes
        if let d = doc.disk {
            diskUsedBytes = d.used_bytes
            diskLimitBytes = d.limit_bytes
            diskWritesGated = d.writes_gated?.value
        }
        weightsReleased = doc.weights?.released ?? false
        weightsRestoring = doc.weights?.restoring ?? false
        weightsRestores = doc.weights?.restores ?? weightsRestores
        weightsRestoreFailures = doc.weights?.restore_failures ?? weightsRestoreFailures
        weightsIdleReleaseSeconds = doc.weights?.idle_release_seconds
        if let mods = doc.input_modalities, !mods.isEmpty { inputModalities = mods }
        if let a = doc.ane_ffn { aneState = a.state; aneShare = a.share }
        statusAgeMs = doc.transport?.status_age_ms
        maxTickMs = doc.loop?.max_tick_ms

        // The raw pressure state oscillates around its threshold even when
        // memory is steady, so a new value must be reported on two
        // consecutive polls before the displayed bar color switches —
        // otherwise the MEM bar flickers between colors every second.
        let raw = doc.memory_pressure
        if raw != pressureStreakValue {
            pressureStreakValue = raw
            pressureStreak = 1
        } else {
            pressureStreak += 1
        }
        if pressureStreak >= 2 {
            memoryPressure = raw
        }
        if let t = doc.transport {
            engineRecovering = t.recovering ?? false
            engineRestarts = t.restarts ?? engineRestarts
        }
        if let m = doc.metal { metalHealthy = m.healthy }
        engineFailures = ((m?.metal_failures ?? 0) + (m?.capacity_failures ?? 0))

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
        // Progress of the request currently generating its output.
        if let req = doc.active_requests?.first(where: { $0.phase == "decode" }) {
            decodeGeneratedTokens = req.generated_tokens
            decodeMaxTokens = req.max_new_tokens
            decodeAgeSeconds = req.age_ms.map { $0 / 1000 }
        } else {
            decodeGeneratedTokens = nil
            decodeMaxTokens = nil
            decodeAgeSeconds = nil
        }
        lastPollAt = Date()
    }

    func markPollFailed() {
        pollFailureStreak += 1
        // One slow /status must not blip the dot to yellow or drop the
        // in-flight numbers: the flip needs two consecutive failures.
        guard pollFailureStreak >= 2 else { return }
        endpointAlive = false
        // Not answering means not ready. Otherwise a "ready" seen from the
        // old server while it shut down would outlive a restart and hide the
        // new server's startup/download progress.
        endpointReady = false
        livePrefillTokensPerSecond = nil
        prefillFraction = nil
        prefillRemainingTokens = nil
        prefillETASeconds = nil
        decodeGeneratedTokens = nil
        decodeMaxTokens = nil
        decodeAgeSeconds = nil
    }

    func resetForRestart() {
        startupTitle = nil
        startupDetail = nil
        startupFraction = nil
        startupBegan = nil
        lastOutputLine = nil
        sawByteProgress = false
        modelDownloadedThisStartup = false
        requests.removeAll()
        logLines.removeAll()
        weightsLoadSeconds = nil
        readyModel = nil
        readyContext = nil
        readyURL = nil
        endpointReady = false
        endpointAlive = false
        pollFailureStreak = 0
        portOccupiedByOther = false
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
        itlP50 = nil
        itlP95 = nil
        draftAcceptance = nil
        draftedTokens = nil
        acceptedDraftTokens = nil
        kvHitTokens = nil
        kvAllocatedBytes = nil
        completedCount = nil
        failedCount = nil
        cancelledCount = nil
        decodingCount = nil
        prefillingCount = nil
        queuedCount = nil
        waitingResources = nil
        oldestWaitMs = nil
        totalOutputTokens = nil
        memoryUsedBytes = nil
        memoryPeakBytes = nil
        serverStartedAt = nil
        weightsReleased = false
        weightsRestoring = false
        weightsRestores = 0
        weightsRestoreFailures = 0
        weightsIdleReleaseSeconds = nil
        inputModalities = []
        aneState = nil
        aneShare = nil
        diskUsedBytes = nil
        diskLimitBytes = nil
        diskWritesGated = nil
        statusAgeMs = nil
        maxTickMs = nil
        tpsHistory.removeAll()
        lastPollAt = nil
        memoryPressure = nil
        pressureStreakValue = nil
        pressureStreak = 0
        engineRecovering = false
        engineRestarts = 0
        metalHealthy = nil
        engineFailures = 0
        decodeGeneratedTokens = nil
        decodeMaxTokens = nil
        decodeAgeSeconds = nil
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

    /// Milliseconds, human: "85 ms", "94.7 ms", "1.2 s".
    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v < 1000 {
            return v.formatted(.number.precision(.fractionLength(v < 100 ? 1 : 0))) + " ms"
        }
        return (v / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    /// Compact time left: "8s", "1m 05s", "1h 02m".
    static func eta(_ v: Double) -> String {
        let s = max(Int(v.rounded()), 0)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
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
        if tokens >= 1_000_000 {
            return (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(2))) + "M"
        }
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
