import Foundation

/// One parsed event from a splash stdout/stderr line.
enum SplashEvent {
    case request(RequestMetrics)
    case thermal(from: String, to: String)
    case ready(model: String, context: String?, url: String?)
    case weightsLoaded(Double)
    case raw(String)
}

struct RequestMetrics: Identifiable, Equatable {
    var id: Int
    let isStarted: Bool
    let timestamp: Date
    let input: Int?
    let cached: Int?
    let deduplicated: Int?
    let output: Int?
    let ttftSeconds: Double?
    let tokensPerSecond: Double?
    let tokensPerCycle: Double?
}

enum SplashParser {
    /// Parse one line of `splash serve` output. Lines that carry no
    /// machine-readable payload come back as `.raw`.
    static func parse(_ line: String) -> SplashEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw(trimmed) }

        // Strip a leading "HH:MM:SS " timestamp for prefix-based matches.
        let tsRange = trimmed.range(of: #"^\d{2}:\d{2}:\d{2} "#, options: .regularExpression)
        let body = tsRange.map { String(trimmed[$0.upperBound...]) } ?? trimmed

        // Thermal state: nominal → fair
        if body.hasPrefix("Thermal state:"),
           let prefixEnd = body.range(of: "Thermal state:"),
           let arrow = body.range(of: "→") {
            let from = body[prefixEnd.upperBound..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let to = body[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            return .thermal(from: String(from), to: String(to))
        }

        // Weights loaded in 3.08 s.
        if body.hasPrefix("Weights loaded in"),
           let prefixEnd = body.range(of: "Weights loaded in"),
           let end = body.range(of: " s") {
            let num = body[prefixEnd.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let v = Double(num) { return .weightsLoaded(v) }
            return .raw(body)
        }

        // Ready · model · context 256K · http://127.0.0.1:8081  (may be timestamp-prefixed)
        let segments = trimmed.components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let head = segments.first ?? ""
        let headTokens = head.split(separator: " ").map(String.init)

        if headTokens.contains("Ready") {
            var model: String?
            var context: String?
            var url: String?
            for seg in segments.dropFirst() {
                if seg.hasPrefix("context ") {
                    context = seg.replacingOccurrences(of: "context ", with: "")
                } else if seg.hasPrefix("http") {
                    url = seg
                } else if model == nil {
                    model = seg
                }
            }
            if let model { return .ready(model: model, context: context, url: url) }
            return .raw(trimmed)
        }

        guard headTokens.count >= 2,
              let kind = headTokens.last,
              kind == "Started" || kind == "Done" else {
            return .raw(trimmed)
        }

        var ts = Date()
        if headTokens.count >= 3, let date = parseTimestamp(headTokens[headTokens.count - 2]) {
            ts = date
        }

        var input: Int?
        var cached: Int?
        var deduplicated: Int?
        var output: Int?
        var ttft: Double?
        var tps: Double?
        var tpc: Double?

        for seg in segments.dropFirst() {
            let kv = seg.split(separator: " ", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let first = String(kv[0])
            let second = String(kv[1])
            switch second {
            case "tok/s": tps = doubleValue(first)
            case "tok/cycle": tpc = doubleValue(first)
            default:
                switch first {
                case "input": input = intValue(second)
                case "cached": cached = intValue(second)
                case "deduplicated": deduplicated = intValue(second)
                case "output": output = intValue(second)
                case "TTFT": ttft = doubleValue(second.replacingOccurrences(of: "s", with: ""))
                default: break // "tools 12·7e0019d3", "effort absent" etc.
                }
            }
        }

        let req = RequestMetrics(
            id: 0,
            isStarted: kind == "Started",
            timestamp: ts,
            input: input, cached: cached, deduplicated: deduplicated, output: output,
            ttftSeconds: ttft, tokensPerSecond: tps, tokensPerCycle: tpc
        )
        return .request(req)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (h, m, sec) = (parts[0], parts[1], parts[2])
        guard h < 24, m < 60, sec < 60 else { return nil }
        var c = DateComponents()
        c.hour = h; c.minute = m; c.second = sec
        return Calendar.current.date(from: c)
    }

    static func intValue(_ s: String) -> Int? {
        Int(s.replacingOccurrences(of: ",", with: ""))
    }

    static func doubleValue(_ s: String) -> Double? {
        Double(s)
    }
}
