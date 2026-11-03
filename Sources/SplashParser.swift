import Foundation

/// One parsed event from a splash stdout/stderr line.
enum SplashEvent {
    case request(RequestMetrics)
    case thermal(from: String, to: String)
    case ready(model: String, context: String?, url: String?)
    case weightsLoaded(Double)
    /// `Selected <file> from <repo>.`
    case selected(file: String, repo: String)
    /// `Fetching 3 file(s), 16.50 GB, from owner/repo@abc123; ...`
    case fetching(repo: String, files: Int?, totalBytes: Double?)
    /// A tqdm progress bar redraw, or a `{"event": "download"}` JSON line.
    case progress(ProgressBar)
    /// `Loading · <model>`: the server is loading weights.
    case loading(model: String)
    /// Progress redraws that carry nothing to show (e.g. the Xet transfer
    /// bar, which has no total).
    case ignored
    case raw(String)
}

struct ProgressBar: Equatable {
    /// tqdm's description, e.g. "Downloading bytes", "Fetching 3 files".
    let label: String
    let fraction: Double
    let done: String
    let total: String
    let eta: String?
    let rate: String?
    /// Byte bars (vs. file-count bars), which carry the useful download size.
    let isBytes: Bool
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

        if let bar = parseProgress(trimmed) { return .progress(bar) }
        if body.hasPrefix("Downloading bytes:") || body.hasPrefix("Download complete:") {
            return .ignored
        }

        if body.hasPrefix("Selected "),
           let from = body.range(of: " from ", options: .backwards) {
            var repo = String(body[from.upperBound...])
            if repo.hasSuffix(".") { repo.removeLast() }
            let file = body[body.index(body.startIndex, offsetBy: 9)..<from.lowerBound]
            return .selected(file: String(file), repo: repo)
        }

        if body.hasPrefix("Fetching "), body.contains(" from "),
           let fromRange = body.range(of: " from ") {
            let rest = body[fromRange.upperBound...]
            let repo = rest.split(whereSeparator: { $0 == "@" || $0 == ";" || $0 == " " }).first.map(String.init) ?? ""
            let files = body.firstMatch(#"Fetching (\d+) file"#).flatMap { Int($0) }
            let gb = body.firstMatch(#"([\d.]+) GB"#).flatMap { Double($0) }
            return .fetching(repo: repo, files: files, totalBytes: gb.map { $0 * 1e9 })
        }

        if body.hasPrefix("Loading ·") {
            let model = body.dropFirst("Loading ·".count).trimmingCharacters(in: .whitespaces)
            return .loading(model: model)
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

    /// Progress lines, in the forms splash's download step prints:
    /// - huggingface Xet: `Reconstructing (…):  42%|███▏  |  6.93GB / 16.5GB,  52.1MB/s`
    /// - plain tqdm: `model.gguf:  42%|███▏  | 6.93G/16.5G [02:10<03:00, 52.1MB/s]`
    ///   (also the `Fetching 3 files: 33%|…| 1/3 [...]` file-count bar)
    /// - splash's JSON line: `{"event": "download", "done": …, "total": …}`
    static func parseProgress(_ line: String) -> ProgressBar? {
        if line.hasPrefix("{"), line.contains("\"download\""),
           let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["event"] as? String == "download",
           let done = (obj["done"] as? NSNumber)?.doubleValue,
           let total = (obj["total"] as? NSNumber)?.doubleValue, total > 0 {
            return ProgressBar(
                label: "Downloading \(obj["repo"] as? String ?? "")",
                fraction: min(done / total, 1),
                done: decimalBytes(done), total: decimalBytes(total),
                eta: nil, rate: nil, isBytes: true
            )
        }
        guard line.contains("%|") else { return nil }
        let range = NSRange(line.startIndex..., in: line)

        // Xet byte bar: "<desc>: NN%|<bar>| <done>B / <total>B[, <rate>]"
        let xet = #"^\s*(.*?):\s*(\d{1,3})%\|[^|]*\|\s*([\d.]+\s*[kMGTP]?B)\s*/\s*([\d.]+\s*[kMGTP]?B)\s*,?\s*([\d.]+\s*[kMGTP]?B/s)?"#
        if let re = try? NSRegularExpression(pattern: xet),
           let m = re.firstMatch(in: line, range: range) {
            let g = groups(m, in: line)
            guard let pct = Double(g[2]) else { return nil }
            let done = g[3], total = g[4]
            let rate = g[5].isEmpty ? nil : g[5]
            var eta: String?
            if let d = byteCount(done), let t = byteCount(total),
               let r = rate.flatMap({ byteCount(String($0.dropLast(2))) }), r > 0, t > d {
                eta = Fmt.duration((t - d) / r)
            }
            return ProgressBar(
                label: g[1], fraction: min(pct / 100, 1),
                done: done, total: total, eta: eta, rate: rate, isBytes: true
            )
        }

        // Classic tqdm: "<desc>: NN%|<bar>| <done>/<total> [<elapsed><<eta>, <rate>]"
        let classic = #"^\s*(.*?):?\s*(\d{1,3})%\|[^|]*\|\s*([^/\s]+)/(\S+)\s*\[([^<\]]*)<?([^,\]]*),?\s*([^\]]*)\]"#
        if let re = try? NSRegularExpression(pattern: classic),
           let m = re.firstMatch(in: line, range: range) {
            let g = groups(m, in: line)
            guard let pct = Double(g[2]) else { return nil }
            let eta = g[6]
            let rate = g[7]
            let isBytes = rate.hasSuffix("B/s")
            return ProgressBar(
                label: g[1], fraction: min(pct / 100, 1),
                done: isBytes ? g[3] + "B" : g[3], total: isBytes ? g[4] + "B" : g[4],
                eta: eta.isEmpty || eta == "?" ? nil : eta,
                rate: rate.isEmpty || rate.hasPrefix("?") ? nil : rate,
                isBytes: isBytes
            )
        }
        return nil
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    /// Bytes in decimal units, matching what the download bars print.
    static func decimalBytes(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }

    /// "6.93GB" / "6.93G" / "446kB" → bytes (decimal units, as tqdm prints).
    static func byteCount(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("B") { t.removeLast() }
        let mult: Double
        switch t.last {
        case "k": mult = 1e3
        case "M": mult = 1e6
        case "G": mult = 1e9
        case "T": mult = 1e12
        case "P": mult = 1e15
        default: mult = 1
        }
        if mult != 1 { t.removeLast() }
        return Double(t.trimmingCharacters(in: .whitespaces)).map { $0 * mult }
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

private extension String {
    /// First capture group of `pattern`, if it matches.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
