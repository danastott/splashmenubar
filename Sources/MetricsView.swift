import SwiftUI

enum MenuAction {
    case start, stop, restart, settings, quit
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
            gauges
            sectionLabel("SPEED OVER TIME · TOK/S")
            Sparkline(values: store.tpsHistory, color: .blue)
                .frame(height: 88)
            sectionLabel("LAST REQUEST")
            lastRequest
            sectionLabel("LOAD")
            load
            sectionLabel("SERVER")
            serverInfo
        }
        .padding(12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(store.effectiveRunning ? "Splash" : store.state.label)
                .font(.system(size: 13, weight: .semibold))
            if store.isExternalServer {
                Text("external")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let thermal = store.thermalState {
                HStack(spacing: 4) {
                    Circle()
                        .fill(thermalColor(thermal))
                        .frame(width: 7, height: 7)
                    Text(thermal)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Button(action: { onAction(.settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
        }
        .foregroundColor(.primary)
    }

    private var statusColor: Color {
        if store.state == .starting { return .yellow }
        if store.effectiveRunning { return .green }
        switch store.state {
        case .crashed: return .red
        default: return .gray
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

    private var gauges: some View {
        HStack(spacing: 16) {
            RingGauge(
                value: store.gaugeTokensPerSecond.map { min($0 / 100, 1) },
                color: .blue,
                center: Fmt.double(store.gaugeTokensPerSecond),
                caption: "tok/s"
            )
            RingGauge(
                value: store.gaugeCacheFraction,
                color: .orange,
                center: Fmt.percent(store.gaugeCacheFraction),
                caption: "cached"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    // MARK: - Sections

    private var lastRequest: some View {
        VStack(spacing: 4) {
            row("Output (last)", Fmt.int(store.last?.output) + " tok")
            row("Input / cached", "\(Fmt.int(store.last?.input)) / \(Fmt.int(store.last?.cached))")
            row("Deduplicated", Fmt.int(store.last?.deduplicated))
            row("TTFT (last)", Fmt.seconds(store.last?.ttftSeconds))
            row("Tok/cycle", Fmt.double(store.last?.tokensPerCycle))
        }
    }

    private var load: some View {
        VStack(spacing: 4) {
            row("Requests", requestsSummary)
            if let fraction = store.prefillFraction {
                let eta = store.prefillETASeconds.map { " · \(Fmt.seconds($0)) left" } ?? ""
                row("Prefill", "\(Int(fraction * 100))% · \(Fmt.int(store.prefillRemainingTokens)) tok" + eta)
            }
            row("TTFT (p50 / p95)", "\(Fmt.seconds(store.ttftP50)) / \(Fmt.seconds(store.ttftP95))")
            row("Prefill / decode", "\(Fmt.double(store.prefillTokensPerSecond, 0)) / \(Fmt.double(store.lifetimeTokensPerSecond)) tok/s")
            row("Total output", Fmt.int(store.totalOutputTokens) + " tok")
            row("Active", activeSummary)
            row("Memory", Fmt.bytes(store.memoryUsedBytes))
            if let started = store.serverStartedAt {
                row("Uptime", Fmt.duration(Date().timeIntervalSince(started)))
            }
            if let w = store.weightsLoadSeconds {
                row("Weights load", Fmt.seconds(w) + (store.weightsReleased ? " · released" : ""))
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
            row("Model", store.modelFromStatus ?? store.readyModel ?? config.model, secondary: true)
            row("Context", Fmt.context(store.maxContextTokens ?? parseContext(store.readyContext)))
            row("Endpoint", store.readyURL ?? "http://127.0.0.1:\(config.port)", secondary: true)
        }
    }

    private func parseContext(_ s: String?) -> Int? {
        guard let s else { return nil }
        if s.hasSuffix("K") {
            return Int(s.dropLast()).flatMap { $0 * 1000 }
        }
        return Int(s)
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false) -> some View {
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
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if store.effectiveRunning {
                Button("Stop", action: { onAction(.stop) })
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button("Restart", action: { onAction(.restart) })
                    .buttonStyle(.bordered)
            } else {
                Button("Start", action: { onAction(.start) })
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                Button("Restart", action: { onAction(.restart) })
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button("Quit", action: { onAction(.quit) })
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .controlSize(.small)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Ring gauge

struct RingGauge: View {
    let value: Double?
    let color: Color
    let center: String
    let caption: String

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
                Text(center)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(width: 54, height: 54)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Sparkline

/// Line graph of tok/s samples over time, with area fill, gridlines and
/// min/max labels.
struct Sparkline: View {
    let values: [Double]
    var color: Color
    /// Samples per row of history; the graph shows the last `window` seconds
    /// at a 2 s poll interval.
    var window: Int = 90

    var body: some View {
        let vals = Array(values.suffix(window))
        let maxV = vals.max() ?? 0
        GeometryReader { geo in
            let pts = points(in: geo.size, maxV: maxV)
            ZStack(alignment: .topLeading) {
                // gridlines at 25 / 50 / 75 %
                Path { p in
                    for f in [0.25, 0.5, 0.75] {
                        let y = geo.size.height * (1 - f)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)

                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height - 2))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 2))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.22))
                    Path { p in
                        for (i, pt) in pts.enumerated() {
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(color, lineWidth: 1.5)
                    Text(Fmt.double(maxV, 0))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .offset(x: 4, y: 2)
                } else {
                    Text("no decode samples yet")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func points(in size: CGSize, maxV: Double) -> [CGPoint] {
        let vals = Array(values.suffix(window))
        guard vals.count > 1, maxV > 0 else { return [] }
        return vals.enumerated().map { i, v in
            CGPoint(
                x: CGFloat(i) / CGFloat(vals.count - 1) * size.width,
                y: size.height - 2 - CGFloat(v / maxV) * (size.height - 6)
            )
        }
    }
}
