import SwiftUI
import AppKit

enum MenuAction {
    case start, stop, restart, settings, quit, togglePin
}

struct MetricsView: View {
    @ObservedObject var store: MetricsStore
    let config: SplashConfig
    /// When set, the body scrolls and the whole view is this height.
    var maxHeight: CGFloat? = nil
    let onAction: (MenuAction) -> Void
    /// Right-clicking a gauge opens its color panel (the system
    /// NSColorPanel): the app applies and persists the pick.
    var onOpenGaugeColorPanel: ((String) -> Void)? = nil

    private let controlBarHeight: CGFloat = 42

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let maxHeight {
                    ScrollView { content }
                        .frame(height: maxHeight - controlBarHeight)
                } else {
                    content
                }
            }
            .frame(width: 320)

            controls
                .frame(width: 320)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .preferredColorScheme(config.theme.colorScheme)
    }

    private var content: some View {
        VStack(spacing: 10) {
            header
                // Pinned, the top strip (header plus the margin above it) is
                // the drag handle; it shows an open hand.
                .background(
                    WindowDragArea(enabled: store.panelPinned)
                        .padding(EdgeInsets(top: -12, leading: -12, bottom: -5, trailing: -12))
                )
            if store.isStartingUp {
                startupCard
            } else if case .crashed(let info) = store.state {
                // The child died but a splash we didn't start is serving
                // the port (it hit "address in use"): informational card,
                // not the red crash card — the server on the port is up.
                if store.endpointAlive {
                    externalServerCard(info)
                } else if store.portOccupiedByOther {
                    portOccupiedCard(info)
                } else {
                    crashCard(info)
                }
            }
            if store.effectiveRunning, let warn = engineWarning {
                warningCard(warn)
            }
            gauges
            sectionLabel("DECODE SPEED · TOK/S",
                         help: "The last \(config.graphSampleWindow) tok/s samples, taken every \(refreshText) while a request is generating. Idle time isn't part of the graph; the sample count is set by the graph span and UI refresh in Settings.")
            Sparkline(values: store.tpsHistory,
                      color: store.gaugeColor(id: "graph", default: .blue),
                      window: config.graphSampleWindow,
                      onOpenColorPanel: { onOpenGaugeColorPanel?("graph") })
                .frame(height: 88)
                .help("Decode speed (tok/s): the last \(config.graphSampleWindow) samples taken while a request is generating, every \(refreshText) (span and UI refresh in Settings). Samples are evenly spaced by count, not by wall-clock time — idle gaps don't stretch them. The dotted line is the average of the samples shown. Right-click to pick the line's color.")
            // Log-derived; an adopted (external) server has no log for the
            // app to parse, and /status carries no per-request record — show
            // the section only once a request has actually finished.
            if store.last != nil {
                sectionLabel("LAST REQUEST",
                             help: "Figures for the most recently finished request, from splash's Done log line.")
                lastRequest
            }
            sectionLabel("LOAD",
                         help: "Server-wide totals and averages since splash started.")
            load
            sectionLabel("SERVER",
                         help: "What splash is serving and where.")
            serverInfo
        }
        .padding(12)
    }

    /// The poll interval as text, e.g. "2 s" or "500 ms".
    private var refreshText: String {
        let v = config.refreshInterval
        return v < 1 ? "\(Int(v * 1000)) ms" : "\(Fmt.double(v, v == v.rounded() ? 0 : 1)) s"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(store.effectiveRunning ? "Splash" : store.state.label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .contentShape(Rectangle())
            .help(statusHelp)
            if store.isExternalServer {
                Text("external")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .foregroundColor(.secondary)
                    .help("This server wasn't started by Splash Menu Bar (e.g. run from a terminal). Stop still shuts it down; quitting the app leaves it running.")
            }
            Spacer()
            if store.thermalState != nil || store.chipTemperatureC != nil {
                HStack(spacing: 4) {
                    if let thermal = store.thermalState {
                        Circle()
                            .fill(thermalColor(thermal))
                            .frame(width: 7, height: 7)
                        Text(thermal)
                            .font(.system(size: 10, weight: .medium))
                    }
                    if let c = store.chipTemperatureC {
                        if store.thermalState != nil {
                            Text("·").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Text(TemperatureUnit.format(celsius: c))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
                .help(headerPillHelp)
            }
            Button(action: { onAction(.togglePin) }) {
                Image(systemName: store.panelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(store.panelPinned ? 0 : 45))
                    .foregroundColor(store.panelPinned ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.panelPinned ? "Unpin" : "Pin")
            .help(store.panelPinned
                  ? "Pinned: this panel stays open until you unpin it, and you can drag it anywhere by its top edge. Click to unpin and snap it back under the menu bar."
                  : "Pin this panel open, so clicking elsewhere, pressing Esc or using its buttons doesn't close it. Pinned, you can drag it anywhere on screen by its top edge.")
            Button(action: { onAction(.settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,): edit the splash serve options. Saving restarts the server.")
        }
        .foregroundColor(.primary)
    }

    // MARK: - Startup

    private var startupCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.startupTitle ?? "Starting splash…")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let f = store.startupFraction {
                    Text("\(Int((f * 100).rounded(.down)))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            if let f = store.startupFraction {
                ProgressView(value: f)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack {
                if let detail = store.startupDetail {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let began = store.startupBegan {
                    Text(Fmt.duration(Date().timeIntervalSince(began)))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            if let line = store.lastOutputLine {
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .help("What splash is doing before it can serve: the current stage, download progress (size · speed · time left), time since launch, and its latest output line.")
    }

    private func crashCard(_ info: CrashInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("splash exited")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(info.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ForEach(Array(store.crashLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
        .help("splash exited: \(info.description). The lines below are its last output; select the text to copy it. Press Start to run it again.")
    }

    /// Our child exited while an external splash serves the port.
    private func externalServerCard(_ info: CrashInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("splash exited")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(info.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("A splash server started outside the app is serving port \(config.port), so the app uses that one. Restart runs splash from the app instead.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(store.crashLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .help("The splash this app started exited, but an externally started splash is serving port \(config.port) — the app is using that server. Restart shuts it down and runs splash from the app with the current settings.")
    }

    /// The child exited because a service that is NOT splash holds the
    /// port: not a crash to fix, and nothing to adopt.
    private func portOccupiedCard(_ info: CrashInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("port in use")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(info.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("Something else (not splash) is serving port \(config.port), so the splash the app started exited. Stop that service — or change the port in Settings — then press Start.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(store.crashLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .help("A service other than splash is listening on port \(config.port) — the splash this app started exited because the port was taken. Stop the other service or change the port in Settings.")
    }

    /// A warning while the server is up but its inference engine is not:
    /// the app's child (the Python wrapper) stays alive across engine
    /// crashes, so without this the flyout would look healthy.
    private var engineWarning: (title: String, detail: String, color: Color)? {
        if store.metalHealthy == false {
            return ("Engine error",
                    "Metal is reporting a failure; requests may fail or hang until splash is restarted.\(failuresSuffix)",
                    .red)
        }
        if store.engineRecovering {
            return ("Engine recovering",
                    "The inference engine crashed and is restarting; requests can't be served until it's back.\(restartsSuffix)",
                    .orange)
        }
        if store.engineRestarts > 0 || store.engineFailures > 0 {
            return ("Engine unstable",
                    "The inference engine has crashed and restarted since startup;\(restartsSuffix) if it keeps happening, restart splash.",
                    .orange)
        }
        return nil
    }

    private var restartsSuffix: String {
        store.engineRestarts > 0 ? " Restarted \(store.engineRestarts)× since startup." : ""
    }

    private var failuresSuffix: String {
        store.engineFailures > 0 ? " \(store.engineFailures) engine failure\(store.engineFailures == 1 ? "" : "s") since startup." : ""
    }

    private func warningCard(_ warn: (title: String, detail: String, color: Color)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(warn.title)
                .font(.system(size: 12, weight: .semibold))
            Text(warn.detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(warn.color.opacity(0.14)))
        .help(warn.detail)
    }

    private var statusHelp: String {
        if store.isStartingUp { return "Yellow: splash is starting (downloading or loading the model)." }
        if store.effectiveRunning {
            return store.endpointReady || store.readyModel != nil
                ? "Green: splash is running and ready for requests."
                : "Green: splash is running."
        }
        switch store.state {
        case .crashed(let info): return "Red: splash exited unexpectedly (\(info.description)). Press Start to run it again."
        default: return "Gray: splash is stopped. Press Start to run it."
        }
    }

    private var statusColor: Color {
        if store.isStartingStatus { return .yellow }
        if store.effectiveRunning { return .green }
        switch store.state {
        case .crashed: return .red
        default: return .gray
        }
    }

    /// Hover text for the header pill: thermal state and chip temperature,
    /// whichever are known.
    private var headerPillHelp: String {
        var parts: [String] = []
        if let s = store.thermalState {
            parts.append([
                "Thermal state of this Mac, as reported by macOS through splash.",
                thermalMeaning(s),
                "Levels: nominal → fair → serious → critical.",
            ].joined(separator: "\n"))
        }
        if let c = store.chipTemperatureC {
            parts.append("Chip temperature: \(TemperatureUnit.format(celsius: c)), the hottest CPU/GPU die sensor (°F or °C follows Language & Region settings).")
        }
        return parts.joined(separator: "\n")
    }

    private func thermalMeaning(_ s: String) -> String {
        switch s {
        case "nominal":
            return "Nominal: normal temperature, no thermal limits."
        case "fair":
            return "Fair: slightly warm. Fans may spin up and macOS may trim background work; speeds are usually unaffected."
        case "serious":
            return "Serious: hot. macOS is throttling the CPU and GPU, so tok/s and prefill speed will drop."
        case "critical":
            return "Critical: very hot. Heavy throttling until the Mac cools down."
        default:
            return "Current state: \(s)."
        }
    }

    private func pressureColor(_ p: String) -> Color {
        switch p {
        case "normal": return .green
        case "warning": return .yellow
        default: return .red
        }
    }

    private func thermalColor(_ s: String) -> Color {
        switch s {
        case "nominal": return .green
        case "fair": return .orange
        case "serious": return .orange
        default: return .red
        }
    }

    // MARK: - Gauges

    /// Average decode speed of the samples the speed graph shows — the same
    /// window as the graph's dotted average line.
    private var tpsAverage: Double? {
        let vals = Array(store.tpsHistory.suffix(config.graphSampleWindow))
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private var gauges: some View {
        HStack(spacing: 12) {
            RingGauge(
                value: store.gaugeTokensPerSecond.map { min($0 / 100, 1) },
                color: store.gaugeColor(id: "tok", default: .blue),
                center: Fmt.double(store.gaugeTokensPerSecond),
                detail: tpsAverage.map { "avg \(Fmt.double($0))" },
                caption: "tok/s",
                help: "Decode speed: tokens generated per second right now, or the average since splash started when idle. Full ring = 100 tok/s. Below it: the average of the samples in the speed graph. Right-click to pick the ring's color.",
                onOpenColorPanel: { onOpenGaugeColorPanel?("tok") }
            )
            RingGauge(
                // While a prompt prefills, the ring fills with its progress.
                value: store.prefillFraction
                    ?? store.gaugePrefillTokensPerSecond.map { min($0 / 500, 1) },
                color: store.gaugeColor(id: "prefill", default: .purple),
                // Prefilling: % done, time left under it. Otherwise: speed.
                center: store.prefillFraction.map { "\(Int($0 * 100))%" }
                    ?? Fmt.double(store.gaugePrefillTokensPerSecond, 0),
                detail: store.prefillFraction == nil ? nil
                    : store.prefillETASeconds.map { Fmt.eta($0) },
                caption: "prefill",
                help: "While a prompt is prefilling: how much of it is done (the ring fills as it goes) and the estimated time left. Otherwise: prefill speed in tokens per second, from the last prefill or the average since splash started; a full ring = 500 tok/s. Right-click to pick the ring's color.",
                onOpenColorPanel: { onOpenGaugeColorPanel?("prefill") }
            )
            RingGauge(
                value: store.gaugeCacheFraction,
                color: store.gaugeColor(id: "cached", default: .orange),
                center: Fmt.percent(store.gaugeCacheFraction),
                caption: "cached",
                help: "KV cache hit rate since the server started: the share of prompt tokens served from the cache instead of being prefilled again (the per-request figure is LAST REQUEST → Input / cached). Right-click to pick the ring's color.",
                onOpenColorPanel: { onOpenGaugeColorPanel?("cached") }
            )
            HStack(spacing: 6) {
                BarGauge(
                    value: store.system.gpu,
                    color: store.gaugeColor(id: "gpu", default: .green),
                    caption: "GPU",
                    help: "GPU use across the whole Mac: share of time the GPU was busy, as Activity Monitor reports it. Right-click to pick the bar's color.",
                    onOpenColorPanel: { onOpenGaugeColorPanel?("gpu") }
                )
                BarGauge(
                    value: store.system.cpu,
                    color: store.gaugeColor(id: "cpu", default: .cyan),
                    caption: "CPU",
                    help: "CPU use across the whole Mac: share of all cores' time spent busy since the last refresh. Right-click to pick the bar's color.",
                    onOpenColorPanel: { onOpenGaugeColorPanel?("cpu") }
                )
                BarGauge(
                    value: store.system.memory,
                    color: memBarColor,
                    caption: "Mac RAM",
                    help: memoryHelp + " Right-click to pick the bar's color; while the pressure is warning or critical the bar shows that color instead.",
                    onOpenColorPanel: { onOpenGaugeColorPanel?("mem") }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var memoryHelp: String {
        var s = "Memory used across the whole Mac (app memory + wired + compressed, as Activity Monitor counts it)"
        if let used = store.system.memoryUsedBytes, let total = store.system.memoryTotalBytes {
            s += ": \(Fmt.bytes(Int(used))) of \(Fmt.bytes(Int(total)))"
        }
        s += ". The bar's color follows the server's memory-pressure report — "
        return s + pressureHelp
    }

    /// Explains the Mem bar's green/yellow/red coloring and the current
    /// pressure.
    private var pressureHelp: String {
        let colors = "green = normal, yellow = warning, red = critical"
        guard let p = store.memoryPressure else {
            return "\(colors); the server hasn't reported one yet."
        }
        let now: String
        switch p {
        case "normal":
            now = "normal — the Mac has memory to spare"
        case "warning":
            now = "warning — the system is under memory load; splash's requests may be slower or suspended"
        case "critical":
            now = "critical — macOS is reclaiming memory aggressively; splash may refuse or drop requests until it eases off"
        default:
            now = "\(p)"
        }
        return "\(colors); right now: \(now)."
    }

    /// The Mac-RAM bar's color: the user's pick, except while the server's
    /// memory-pressure report is warning or critical — the warning always
    /// wins over a decorative choice.
    private var memBarColor: Color {
        if let p = store.memoryPressure,
           p == "warning" || p == "critical" {
            return pressureColor(p)
        }
        return store.gaugeColor(id: "mem", default: .green)
    }

    // MARK: - Sections

    private var lastRequest: some View {
        VStack(spacing: 4) {
            row("Output (last)", Fmt.int(store.last?.output) + " tok",
                help: "Tokens the last request generated.")
            row("Input / cached", "\(Fmt.int(store.last?.input)) / \(Fmt.int(store.last?.cached))",
                help: "Prompt tokens of the last request / how many of them were reused from the prompt cache instead of being prefilled again. Of the uncached rest, a further share could still read KV that other requests had already computed — the niche \"deduplicated\" figure, no longer shown as its own row.")
            row("TTFT (last)", Fmt.seconds(store.last?.ttftSeconds),
                help: "Time to first token of the last request: from arrival until its first output token (mostly prefill).")
            row("Tok/cycle", Fmt.double(store.last?.tokensPerCycle),
                help: "Tokens produced per decode cycle with the draft model: 1 + accepted draft tokens per cycle. Higher means speculative decoding is paying off.")
        }
    }

    private var load: some View {
        VStack(spacing: 4) {
            row("Requests", requestsSummary,
                help: "Requests completed since splash started, plus any cancelled or failed.")
            if let fraction = store.prefillFraction {
                // Same "6m 04s" shape as the ring's detail, not "364.3s".
                let eta = store.prefillETASeconds.map { " · \(Fmt.eta($0)) left" } ?? ""
                row("Prefill", "\(Int(fraction * 100))% · \(Fmt.int(store.prefillRemainingTokens)) tok" + eta,
                    help: "Progress of the prompt being processed now: % done · tokens remaining · estimated time left at the current prefill speed.")
            }
            if store.decodeGeneratedTokens != nil {
                row("Decode", decodeSummary,
                    help: "Progress of a request generating now: tokens produced · time spent generating · estimated time left when the request has a max-tokens cap (at the current decode speed).")
            }
            row("TTFT (p50 / p95)", "\(Fmt.seconds(store.ttftP50)) / \(Fmt.seconds(store.ttftP95))",
                help: "Time to first token across requests: median / 95th percentile.")
            if store.itlP50 != nil || store.itlP95 != nil {
                row("ITL (p50 / p95)", "\(Fmt.ms(store.itlP50)) / \(Fmt.ms(store.itlP95))",
                    help: "Inter-token latency: the time between consecutive output tokens while generating, across requests (median / 95th percentile). For one stream at a time this is the perceived speed — 1000 ÷ ITL tokens per second — so lower is better.")
            }
            row("Prefill / decode", "\(Fmt.double(store.prefillTokensPerSecond, 0)) / \(Fmt.double(store.lifetimeTokensPerSecond)) tok/s",
                help: "Average speeds since splash started: prompt processing (prefill) / generation (decode).")
            if store.draftedTokens != nil {
                row("Draft accept", draftSummary,
                    help: draftHelp)
            }
            row("Total output", Fmt.int(store.totalOutputTokens) + " tok",
                help: "Tokens generated across all requests since splash started.")
            row("Active", activeSummary,
                help: "Requests in flight right now: generating (decode) · processing their prompt (prefill) · waiting their turn (queued), plus how long the longest-waiting request has waited.")
            row("splash (server)", memorySummary,
                help: "Memory the splash server itself currently holds, as it reports it (— when it doesn't), plus its peak since the server started. Different from the Mac RAM bar in the gauges, which is the whole Mac's memory use.")
            if store.kvAllocatedBytes != nil {
                row("KV cache", "\(Fmt.bytes(store.kvAllocatedBytes)) · \(Fmt.context(store.kvHitTokens)) tok reused",
                    help: "KV cache: server memory held for prompt context, and how many prompt tokens were served from it since startup instead of being prefilled again — high reuse is why similar prompts run fast.")
            }
            if let started = store.serverStartedAt {
                row("Uptime", Fmt.duration(Date().timeIntervalSince(started)),
                    help: "Time since the server started.")
            }
        }
    }

    /// Decode progress of the request generating now: "240 tok · 45s", with
    /// time-left when the request carries a max-tokens cap.
    private var decodeSummary: String {
        var s = Fmt.int(store.decodeGeneratedTokens) + " tok"
        if let age = store.decodeAgeSeconds { s += " · " + Fmt.duration(age) }
        if let maxTok = store.decodeMaxTokens, let gen = store.decodeGeneratedTokens,
           maxTok > gen, let rate = store.liveTokensPerSecond, rate > 0 {
            s += " · ~\(Fmt.eta(Double(maxTok - gen) / rate)) left"
        }
        return s
    }

    /// "36%" while speculative decoding runs, "off" when the server reports
    /// no drafted tokens.
    private var draftSummary: String {
        guard let d = store.draftedTokens, d > 0 else { return "off" }
        return Fmt.percent(store.draftAcceptance)
    }

    private var draftHelp: String {
        guard let d = store.draftedTokens, d > 0 else {
            return "Speculative decoding (a draft model proposing tokens ahead) is not in use: the server reports no drafted tokens, so the main model generates every token alone."
        }
        return "Speculative decoding: the share of the draft model's proposed tokens the main model accepted (\(d.formatted()) drafted since startup). Higher means the draft pays off; below ~40% it barely helps. LAST REQUEST's Tok/cycle is the same idea per request."
    }

    private var requestsSummary: String {
        var s = Fmt.int(store.completedCount) + " done"
        if let c = store.cancelledCount, c > 0 { s += " · \(c) cancelled" }
        if let f = store.failedCount, f > 0 { s += " · \(f) failed" }
        return s
    }

    private var activeSummary: String {
        let d = store.decodingCount ?? 0
        let p = store.prefillingCount ?? 0
        let q = store.queuedCount ?? 0
        if d == 0 && p == 0 && q == 0 { return "idle" }
        var s = "\(d) decode · \(p) prefill · \(q) queued"
        // How long the queue has been backed up (only when there is one).
        if q > 0 || (store.waitingResources ?? 0) > 0,
           let ms = store.oldestWaitMs, ms > 0 {
            s += " · waiting \(Fmt.ms(ms))"
        }
        return s
    }

    /// Server memory as "current · peak"; the peak only when it's above
    /// the current value, so an idle server reads a single number.
    private var memorySummary: String {
        guard let used = store.memoryUsedBytes else { return "—" }
        if let peak = store.memoryPeakBytes, peak > used {
            return "\(Fmt.bytes(used)) · peak \(Fmt.bytes(peak))"
        }
        return Fmt.bytes(used)
    }

    /// Load time at startup, plus the current lifecycle: "3.1 s · released"
    /// or "3.1 s · reloading".
    private var weightsSummary: String {
        var s = store.weightsLoadSeconds.map { Fmt.seconds($0) } ?? "—"
        if store.weightsRestoring {
            s += " · reloading"
        } else if store.weightsReleased {
            s += " · released"
        }
        if store.weightsRestores > 0 { s += " · \(store.weightsRestores) restored" }
        if store.weightsRestoreFailures > 0 { s += " · \(store.weightsRestoreFailures) failed" }
        return s
    }

    private var weightsHelp: String {
        var s = "How long loading the model weights took at startup, plus their lifecycle."
        if let idle = store.weightsIdleReleaseSeconds {
            s += " splash releases the weights from memory after \(Int(idle)) s of idleness to give the RAM back,"
        } else {
            s += " splash can release the weights from memory after idleness to give the RAM back,"
        }
        return s + " so the next request restores them (\"reloading\") and is slower."
    }

    private var serverInfo: some View {
        VStack(spacing: 4) {
            modelLink
            if !store.inputModalities.isEmpty {
                row("Input", store.inputModalities.joined(separator: " · "),
                    help: "Input types this server accepts in prompts.")
            }
            if store.aneState != nil {
                row("ANE", aneSummary,
                    help: "How the model's FFN (feed-forward) layers are split between the Apple Neural Engine (ANE) and the GPU: the percentage is the ANE's share of the work. ane = all on the ANE, split = shared, gpu = none (e.g. --disable-ane).")
            }
            if store.diskUsedBytes != nil || store.diskLimitBytes != nil {
                let d = diskSummary
                row("SSD cache", d.text, warn: d.warn,
                    help: diskHelp)
            }
            if store.statusAgeMs != nil || store.maxTickMs != nil {
                let h = healthSummary
                row("Health", h.text, warn: h.warn,
                    help: "splash's self-report: how old its own status snapshot is (it refreshes every event-loop tick, so normally ~0), and the longest loop tick since startup. A stale snapshot or a long tick means the server's loop is slow or blocked and requests stall.")
            }
            if store.weightsLoadSeconds != nil || store.weightsReleased
                || store.weightsRestoring || store.weightsRestores > 0
                || store.weightsRestoreFailures > 0 {
                row("Weights", weightsSummary,
                    help: weightsHelp)
            }
            endpointLink
        }
    }

    /// "split · 56%" — how the ANE and GPU share the model's FFN layers.
    private var aneSummary: String {
        guard let s = store.aneState else { return "—" }
        if let share = store.aneShare {
            return "\(s) · \(Fmt.percent(share))"
        }
        return s
    }

    /// "2.1 / 16 GiB"; " · writes gated" (orange) while splash pauses writes.
    private var diskSummary: (text: String, warn: Bool) {
        guard let used = store.diskUsedBytes, let limit = store.diskLimitBytes else {
            return ("—", false)
        }
        var s = "\(Fmt.bytes(used)) / \(Fmt.bytes(limit))"
        let gated = store.diskWritesGated == true
        if gated { s += " · writes gated" }
        return (s, gated)
    }

    private var diskHelp: String {
        var s = "Persistent cache on disk (Settings: --max-cache-disk / --persistent-cache): used / limit."
        if store.diskWritesGated == true {
            s += " \"writes gated\" means splash is pausing cache writes (budget or disk full), so new context may not be cached."
        }
        return s
    }

    /// "age 0 ms · tick 99 ms"; orange when the snapshot is stale (>2 s) or
    /// a loop tick ran long (>1.5 s).
    private var healthSummary: (text: String, warn: Bool) {
        let age = store.statusAgeMs
        let tick = store.maxTickMs
        let warn = (age.map { $0 > 2000 } ?? false) || (tick.map { $0 > 1500 } ?? false)
        return ("age \(Fmt.ms(age)) · tick \(Fmt.ms(tick))", warn)
    }

    /// The Model row as a link: clicking opens the folder in the Hugging
    /// Face cache where the model's files are stored. Plain (unlinked) row
    /// when the repo isn't in the cache — nothing to open yet.
    @ViewBuilder
    private var modelLink: some View {
        let id = store.modelFromStatus ?? store.readyModel ?? config.model
        let url = SplashModels.storageURL(for: id)
        if let url {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 11))
                Spacer()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(id)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                        .underline()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .help(modelHelp + " Click to open the folder where its files are stored in Finder.")
        } else {
            row("Model", id, secondary: true,
                help: modelHelp)
        }
    }

    /// The Model row's tooltip: what's served, its (static) context window —
    /// the former Context row — and where to change it.
    private var modelHelp: String {
        let context = Fmt.context(store.maxContextTokens
                                  ?? parseContext(store.readyContext))
        return "The model splash is serving (Hugging Face repo:variant); context window \(context) tokens (prompt + output for one request). Change it in Settings."
    }

    /// The Endpoint row as a link: clicking opens splash's chat page in the
    /// default browser.
    private var endpointLink: some View {
        HStack(spacing: 6) {
            Text("Endpoint")
                .font(.system(size: 11))
            Spacer()
            Button {
                NSWorkspace.shared.open(endpointURL)
            } label: {
                Text(endpointURL.absoluteString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.blue)
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .help("Base URL of the OpenAI-compatible API (add /v1). Click to open it in your browser — splash's chat page lives at this address.")
    }

    private var endpointURL: URL {
        let s = store.readyURL ?? "http://127.0.0.1:\(config.port)"
        return URL(string: s) ?? URL(string: "http://127.0.0.1:\(config.port)")!
    }

    private func parseContext(_ s: String?) -> Int? {
        guard let s else { return nil }
        if s.hasSuffix("K") {
            return Int(s.dropLast()).flatMap { $0 * 1000 }
        }
        return Int(s)
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false, warn: Bool = false, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(secondary ? .secondary : .primary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(warn ? .orange : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help(help)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if store.effectiveRunning {
                Button(action: { onAction(.stop) }) {
                    Image(systemName: "stop.fill")
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color(red: 0.75, green: 0.1, blue: 0.1))
                }
                .accessibilityLabel("Stop")
                .buttonStyle(.bordered)
                .help("Stop the splash server on this port, including one started outside the app.")
                Button(action: { onAction(.restart) }) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .accessibilityLabel("Restart")
                .buttonStyle(.bordered)
                .help("Stop splash and start it again with the current settings.")
            } else {
                Button(action: { onAction(.start) }) {
                    Image(systemName: "play.fill")
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color(red: 0.1, green: 0.55, blue: 0.2))
                }
                .accessibilityLabel("Start")
                .buttonStyle(.bordered)
                .help("Start splash serve with the current settings.")
                Button(action: { onAction(.restart) }) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .accessibilityLabel("Restart")
                .buttonStyle(.bordered)
                .help("Stop splash and start it again with the current settings.")
            }
            Spacer()
            Button(action: { onAction(.quit) }) {
                Image(systemName: "power")
                    .frame(width: 16, height: 16)
            }
            .accessibilityLabel("Quit")
            .buttonStyle(.bordered)
            .help("Quit Splash Menu Bar. A server the app started is stopped; one started elsewhere keeps running.")
        }
        .controlSize(.small)
    }

    private func sectionLabel(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .help(help)
    }
}

// MARK: - Window dragging

/// Drag handle for the window: SwiftUI doesn't move a borderless panel by
/// its background on its own. Enabled, it shows an open hand (closed while
/// dragging) and moves the window; disabled, it ignores the mouse entirely.
/// A tracking area sets the cursor because cursor rects don't update in a
/// non-activating panel while another app is active.
struct WindowDragArea: NSViewRepresentable {
    let enabled: Bool

    final class DragView: NSView {
        var enabled = false {
            didSet { if !enabled, hovering { NSCursor.arrow.set(); hovering = false } }
        }
        private var hovering = false

        override var mouseDownCanMoveWindow: Bool { enabled }

        override func hitTest(_ point: NSPoint) -> NSView? {
            enabled ? super.hitTest(point) : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            guard enabled else { return }
            hovering = true
            NSCursor.openHand.set()
        }

        override func mouseMoved(with event: NSEvent) {
            // Buttons in the header (pin, settings) keep the arrow.
            guard enabled else { return }
            let p = convert(event.locationInWindow, from: nil)
            let overSelf = window?.contentView?.hitTest(
                window?.contentView?.convert(event.locationInWindow, from: nil) ?? .zero) === self
            if bounds.contains(p), overSelf { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }

        override func mouseExited(with event: NSEvent) {
            guard hovering else { return }
            hovering = false
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            guard enabled, let window else { return super.mouseDown(with: event) }
            NSCursor.closedHand.set()
            window.performDrag(with: event)
            NSCursor.openHand.set()
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.enabled = enabled
    }
}

// MARK: - Ring gauge

struct RingGauge: View {
    let value: Double?
    let color: Color
    let center: String
    /// Optional second line under `center`, e.g. a progress percentage.
    var detail: String? = nil
    let caption: String
    var help: String = ""
    /// Right-click opens the ring's color panel; nil disables the menu.
    var onOpenColorPanel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 6)
                if let v = value {
                    Circle()
                        .trim(from: 0, to: min(max(v, 0), 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(center)
                        .font(.system(size: detail == nil ? 13 : 12, weight: .semibold, design: .rounded))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(color)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 7)
            }
            .frame(width: 54, height: 54)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .help(help)
        .contextMenu {
            if let open = onOpenColorPanel {
                Button("Color…") { open() }
            }
        }
    }
}

// MARK: - Bar gauge

/// Vertical bar for a 0...1 fraction, sized to sit beside a RingGauge: the
/// percentage above the bar, the caption below in line with the rings'.
struct BarGauge: View {
    let value: Double?
    let color: Color
    let caption: String
    var help: String = ""
    /// Right-click opens the bar's color panel; nil disables the menu.
    var onOpenColorPanel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 3) {
            VStack(spacing: 2) {
                Text(Fmt.percent(value))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.12))
                        if let v = value {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color)
                                .frame(height: geo.size.height * min(max(v, 0), 1))
                        }
                    }
                }
                .frame(width: 12)
            }
            .frame(width: 26, height: 54)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .help(help)
        .contextMenu {
            if let open = onOpenColorPanel {
                Button("Color…") { open() }
            }
        }
    }
}

// MARK: - Sparkline

/// Line graph of tok/s samples, evenly spaced by sample count (idle time
/// isn't plotted), with area fill, gridlines and an average line.
struct Sparkline: View {
    let values: [Double]
    var color: Color
    /// How many of the latest samples to plot (the Settings graph span at the
    /// configured refresh interval).
    var window: Int = 90
    /// Right-click opens the line's color panel; nil disables the menu.
    var onOpenColorPanel: (() -> Void)? = nil

    /// Width reserved left of the plot for the Y-axis labels.
    private let gutter: CGFloat = 26
    private let topPad: CGFloat = 6
    private let bottomPad: CGFloat = 4

    var body: some View {
        let vals = Array(values.suffix(window))
        let axis = Self.axis(for: vals.max() ?? 0)
        let avg = vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        GeometryReader { geo in
            let plot = CGRect(
                x: gutter, y: topPad,
                width: max(1, geo.size.width - gutter - 4),
                height: max(1, geo.size.height - topPad - bottomPad)
            )
            let yFor = { (v: Double) -> CGFloat in
                plot.maxY - CGFloat(v / axis.max) * plot.height
            }
            ZStack(alignment: .topLeading) {
                if vals.count > 1 {
                    // Gridlines and labels at round tick values.
                    Path { p in
                        for t in axis.ticks {
                            p.move(to: CGPoint(x: plot.minX, y: yFor(t)))
                            p.addLine(to: CGPoint(x: plot.maxX, y: yFor(t)))
                        }
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    ForEach(axis.ticks, id: \.self) { t in
                        Text(Self.label(t))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: gutter - 4, alignment: .trailing)
                            .position(x: (gutter - 4) / 2, y: yFor(t))
                    }

                    let pts = points(vals, in: plot, yFor: yFor)
                    Path { p in
                        p.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.22))
                    Path { p in
                        for (i, pt) in pts.enumerated() {
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(color, lineWidth: 1.5)

                    // Average: dotted line with its value at the right end.
                    if let avg {
                        let y = yFor(avg)
                        Path { p in
                            p.move(to: CGPoint(x: plot.minX, y: y))
                            p.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                        .stroke(Color.primary.opacity(0.75),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Text("avg \(Fmt.double(avg))")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundColor(.primary.opacity(0.85))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.regularMaterial))
                            .fixedSize()
                            .position(x: plot.maxX - 26, y: y < plot.minY + 10 ? y + 8 : y - 8)
                    }
                } else {
                    Text("no decode samples yet")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if let open = onOpenColorPanel {
                Button("Color…") { open() }
            }
        }
    }

    private func points(_ vals: [Double], in plot: CGRect, yFor: (Double) -> CGFloat) -> [CGPoint] {
        vals.enumerated().map { i, v in
            CGPoint(x: plot.minX + CGFloat(i) / CGFloat(vals.count - 1) * plot.width, y: yFor(v))
        }
    }

    /// A 0-based axis whose top is a round number at or above `maxValue`,
    /// with 3–5 ticks at a 1/2/2.5/5 × 10ⁿ step.
    static func axis(for maxValue: Double) -> (max: Double, ticks: [Double]) {
        guard maxValue > 0 else { return (1, [0, 0.5, 1]) }
        let rough = maxValue / 4
        let mag = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= rough } ?? 10 * mag
        let top = (maxValue / step).rounded(.up) * step
        let ticks = stride(from: 0, through: top + step / 2, by: step).map { $0 }
        return (top, ticks)
    }

    static func label(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
