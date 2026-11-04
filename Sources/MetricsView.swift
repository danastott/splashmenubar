import SwiftUI

enum MenuAction {
    case start, stop, restart, settings, quit, togglePin
}

struct MetricsView: View {
    @ObservedObject var store: MetricsStore
    let config: SplashConfig
    /// When set, the body scrolls and the whole view is this tall.
    var maxHeight: CGFloat? = nil
    let onAction: (MenuAction) -> Void

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
            } else if case .crashed = store.state, let line = store.lastOutputLine {
                crashCard(line)
            }
            gauges
            sectionLabel("SPEED OVER TIME · TOK/S",
                         help: "Decode speed sampled every \(refreshText) while a request is generating.")
            Sparkline(values: store.tpsHistory, color: .blue,
                      window: config.graphSampleWindow)
                .frame(height: 88)
                .help("Decode speed (tok/s) over the last ~\(config.graphMinutes) min of generation, sampled every \(refreshText) (span and UI refresh in Settings). The dotted line is the average of the samples shown.")
            sectionLabel("LAST REQUEST",
                         help: "Figures for the most recently finished request, from splash's Done log line.")
            lastRequest
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
                .help(thermalHelp(store.thermalState))
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

    private func crashCard(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("splash exited")
                .font(.system(size: 12, weight: .semibold))
            Text(line)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
        .help("The last line splash printed before it exited; usually the reason it stopped. Select the text to copy it.")
    }

    private var statusHelp: String {
        if store.isStartingUp { return "Yellow: splash is starting (downloading or loading the model)." }
        if store.effectiveRunning {
            return store.endpointReady || store.readyModel != nil
                ? "Green: splash is running and ready for requests."
                : "Green: splash is running."
        }
        switch store.state {
        case .crashed(let code): return "Red: splash exited unexpectedly (status \(code)). Press Start to run it again."
        default: return "Gray: splash is stopped. Press Start to run it."
        }
    }

    private var statusColor: Color {
        if store.state == .starting || store.isStartingUp { return .yellow }
        if store.effectiveRunning { return .green }
        switch store.state {
        case .crashed: return .red
        default: return .gray
        }
    }

    /// Hover text for the thermal pill: what it is and what this level means.
    private func thermalHelp(_ state: String?) -> String {
        let temperature = store.chipTemperatureC.map {
            "Chip temperature: \(TemperatureUnit.format(celsius: $0)), the hottest CPU/GPU die sensor (°F or °C follows Language & Region settings)."
        }
        guard let s = state else {
            return temperature ?? ""
        }
        let meaning: String
        switch s {
        case "nominal":
            meaning = "Nominal: normal temperature, no thermal limits."
        case "fair":
            meaning = "Fair: slightly warm. Fans may spin up and macOS may trim background work; speeds are usually unaffected."
        case "serious":
            meaning = "Serious: hot. macOS is throttling the CPU and GPU, so tok/s and prefill speed will drop."
        case "critical":
            meaning = "Critical: very hot. Heavy throttling until the Mac cools down."
        default:
            meaning = "Current state: \(s)."
        }
        return [
            "Thermal state of this Mac, as reported by macOS through splash.",
            meaning,
            "Levels: nominal → fair → serious → critical.",
            temperature,
        ].compactMap { $0 }.joined(separator: "\n")
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
                color: .blue,
                center: Fmt.double(store.gaugeTokensPerSecond),
                detail: tpsAverage.map { "avg \(Fmt.double($0)) t/s" },
                caption: "tok/s",
                help: "Decode speed: tokens generated per second right now, or the average since splash started when idle. Full ring = 100 tok/s. Below it: the average of the samples in the speed graph."
            )
            RingGauge(
                // While a prompt prefills, the ring fills with its progress.
                value: store.prefillFraction
                    ?? store.gaugePrefillTokensPerSecond.map { min($0 / 500, 1) },
                color: .purple,
                // Prefilling: % done, time left under it. Otherwise: speed.
                center: store.prefillFraction.map { "\(Int($0 * 100))%" }
                    ?? Fmt.double(store.gaugePrefillTokensPerSecond, 0),
                detail: store.prefillFraction == nil ? nil
                    : store.prefillETASeconds.map { Fmt.eta($0) },
                caption: "prefill",
                help: "While a prompt is prefilling: how much of it is done (the ring fills as it goes) and the estimated time left. Otherwise: prefill speed in tokens per second, from the last prefill or the average since splash started; a full ring = 500 tok/s."
            )
            RingGauge(
                value: store.gaugeCacheFraction,
                color: .orange,
                center: Fmt.percent(store.gaugeCacheFraction),
                caption: "cached",
                help: "Prompt cache hit rate: share of requests whose prompt prefix was already cached, so less of it had to be prefilled again."
            )
            HStack(spacing: 6) {
                BarGauge(
                    value: store.system.gpu,
                    color: .green,
                    caption: "GPU",
                    help: "GPU use across the whole Mac: share of time the GPU was busy, as Activity Monitor reports it."
                )
                BarGauge(
                    value: store.system.cpu,
                    color: .cyan,
                    caption: "CPU",
                    help: "CPU use across the whole Mac: share of all cores' time spent busy since the last refresh."
                )
                BarGauge(
                    value: store.system.memory,
                    color: .orange,
                    caption: "Mem",
                    help: memoryHelp
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
        return s + "."
    }

    // MARK: - Sections

    private var lastRequest: some View {
        VStack(spacing: 4) {
            row("Output (last)", Fmt.int(store.last?.output) + " tok",
                help: "Tokens the last request generated.")
            row("Input / cached", "\(Fmt.int(store.last?.input)) / \(Fmt.int(store.last?.cached))",
                help: "Prompt tokens of the last request / how many of them were reused from the prompt cache instead of being prefilled again.")
            row("Deduplicated", Fmt.int(store.last?.deduplicated),
                help: "Prompt tokens beyond the cached prefix whose KV the last request read from blocks another request had already computed.")
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
                let eta = store.prefillETASeconds.map { " · \(Fmt.seconds($0)) left" } ?? ""
                row("Prefill", "\(Int(fraction * 100))% · \(Fmt.int(store.prefillRemainingTokens)) tok" + eta,
                    help: "Progress of the prompt being processed now: % done · tokens remaining · estimated time left at the current prefill speed.")
            }
            row("TTFT (p50 / p95)", "\(Fmt.seconds(store.ttftP50)) / \(Fmt.seconds(store.ttftP95))",
                help: "Time to first token across requests: median / 95th percentile.")
            row("Prefill / decode", "\(Fmt.double(store.prefillTokensPerSecond, 0)) / \(Fmt.double(store.lifetimeTokensPerSecond)) tok/s",
                help: "Average speeds since splash started: prompt processing (prefill) / generation (decode).")
            row("Total output", Fmt.int(store.totalOutputTokens) + " tok",
                help: "Tokens generated across all requests since splash started.")
            row("Active", activeSummary,
                help: "Requests in flight right now: generating (decode) · processing their prompt (prefill) · waiting their turn (queued).")
            row("Memory", Fmt.bytes(store.memoryUsedBytes),
                help: "Memory splash currently holds, as reported by the server (— when it doesn't report it).")
            if let started = store.serverStartedAt {
                row("Uptime", Fmt.duration(Date().timeIntervalSince(started)),
                    help: "Time since the server started.")
            }
            if let w = store.weightsLoadSeconds {
                row("Weights load", Fmt.seconds(w) + (store.weightsReleased ? " · released" : ""),
                    help: "How long loading the model weights took at startup. \"released\" means splash freed them after the idle-release timeout; the next request reloads them.")
            }
        }
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
        return "\(d) decode · \(p) prefill · \(q) queued"
    }

    private var serverInfo: some View {
        VStack(spacing: 4) {
            row("Model", store.modelFromStatus ?? store.readyModel ?? config.model, secondary: true,
                help: "The model splash is serving (Hugging Face repo:variant). Change it in Settings.")
            row("Context", Fmt.context(store.maxContextTokens ?? parseContext(store.readyContext)),
                help: "Maximum context window in tokens (prompt + output) for one request.")
            row("Endpoint", store.readyURL ?? "http://127.0.0.1:\(config.port)", secondary: true,
                help: "Base URL of the OpenAI-compatible API (add /v1). Open it in a browser for splash's chat page.")
        }
    }

    private func parseContext(_ s: String?) -> Int? {
        guard let s else { return nil }
        if s.hasSuffix("K") {
            return Int(s.dropLast()).flatMap { $0 * 1000 }
        }
        return Int(s)
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(secondary ? .secondary : .primary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
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
    }
}

// MARK: - Sparkline

/// Line graph of tok/s samples over time, with area fill, gridlines and
/// min/max labels.
struct Sparkline: View {
    let values: [Double]
    var color: Color
    /// How many of the latest samples to plot (the Settings graph span at the
    /// configured refresh interval).
    var window: Int = 90

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
