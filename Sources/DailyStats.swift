import Foundation

/// One day's worth of splash request aggregates, persisted to disk.
///
/// Two sources feed it:
/// - The server's lifetime counters from /status (works for adopted
///   external servers too). We store the values first seen today as a
///   baseline and report today's delta.
/// - Per-request lines from the server's log (app-launched servers only),
///   which give per-request TTFT and tok/s for the day's averages.
struct DailyStats: Codable, Equatable {
    var date: Date
    /// Server lifetime completed-request count at first poll today (or
    /// after a restart). `completedToday` = current lifetime minus this.
    var baselineCompleted: Int?
    /// Server lifetime output-token count at first poll today.
    var baselineOutputTokens: Int?
    /// Loopback port the baselines were recorded from: the app can switch
    /// to a different splash server whose lifetime counters are unrelated
    /// to the old baselines, so a port change forces a fresh baseline.
    var serverPort: Int?
    /// Running sum of TTFT (seconds) across today's log-parsed requests.
    private(set) var ttftSum: Double
    /// Running sum of TTFT² for the p95 approximation.
    private(set) var ttftSumSq: Double
    /// Number of log-parsed requests carrying a TTFT sample.
    private(set) var ttftCount: Int
    /// Running sum of tok/s across today's log-parsed requests.
    private(set) var tpsSum: Double
    /// Number of log-parsed requests carrying a tok/s sample.
    private(set) var tpsCount: Int

    init(date: Date) {
        self.date = date
        self.baselineCompleted = nil
        self.baselineOutputTokens = nil
        self.serverPort = nil
        self.ttftSum = 0
        self.ttftSumSq = 0
        self.ttftCount = 0
        self.tpsSum = 0
        self.tpsCount = 0
    }

    // MARK: - Baseline / delta

    /// Record the server's lifetime counters. Sets the baseline the first
    /// time each is seen today, re-baselines if a counter drops below it
    /// (the server restarted and its lifetime totals reset), and re-baselines
    /// when the app switches to a different server (different port), whose
    /// counters start somewhere unrelated to the old baseline.
    mutating func updateBaselines(completed: Int?, output: Int?, serverPort: Int?) {
        if self.serverPort != serverPort {
            self.serverPort = serverPort
            if let c = completed { baselineCompleted = c }
            if let o = output { baselineOutputTokens = o }
            return
        }
        if let c = completed {
            if let b = baselineCompleted, c < b {
                baselineCompleted = c
            } else if baselineCompleted == nil {
                baselineCompleted = c
            }
        }
        if let o = output {
            if let b = baselineOutputTokens, o < b {
                baselineOutputTokens = o
            } else if baselineOutputTokens == nil {
                baselineOutputTokens = o
            }
        }
    }

    /// Today's completed requests, or nil until a baseline is recorded.
    func completedToday(current: Int?) -> Int? {
        guard let current, let baseline = baselineCompleted else { return nil }
        return max(0, current - baseline)
    }

    /// Today's output tokens, or nil until a baseline is recorded.
    func outputToday(current: Int?) -> Int? {
        guard let current, let baseline = baselineOutputTokens else { return nil }
        return max(0, current - baseline)
    }

    // MARK: - Per-request log aggregates

    /// Add one completed request's log metrics (TTFT, tok/s) to the running
    /// sums. Called only for app-launched servers (the only ones with a log).
    mutating func accumulateRequest(ttft: Double?, tps: Double?) {
        if let ttft {
            ttftSum += ttft
            ttftSumSq += ttft * ttft
            ttftCount += 1
        }
        if let tps {
            tpsSum += tps
            tpsCount += 1
        }
    }

    var avgTTFT: Double? {
        ttftCount > 0 ? ttftSum / Double(ttftCount) : nil
    }

    var avgTokPerSecond: Double? {
        tpsCount > 0 ? tpsSum / Double(tpsCount) : nil
    }

    /// Approximate p95 TTFT: mean + 1.645·σ. Good enough for a quick-glance
    /// figure; a true p95 needs the raw samples.
    var p95TTFT: Double? {
        guard ttftCount >= 2 else { return avgTTFT }
        let variance = (ttftSumSq - (ttftSum * ttftSum / Double(ttftCount))) / Double(ttftCount - 1)
        let stddev = sqrt(max(0, variance))
        return avgTTFT.map { $0 + 1.645 * stddev }
    }

    static func == (lhs: DailyStats, rhs: DailyStats) -> Bool {
        lhs.date == rhs.date
            && lhs.baselineCompleted == rhs.baselineCompleted
            && lhs.baselineOutputTokens == rhs.baselineOutputTokens
            && lhs.serverPort == rhs.serverPort
            && lhs.ttftCount == rhs.ttftCount
            && lhs.tpsCount == rhs.tpsCount
    }
}
