import Foundation

/// Persists daily request stats for the flyout's TODAY section.
/// All mutation on the main thread; `today` is computed on demand.
final class StatsStore {
    static let shared = StatsStore()

    private var stats: DailyStats

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        self.stats = Self.load(for: today) ?? DailyStats(date: today)
    }

    // MARK: - Today's stats

    /// Today's stats. Rolls over to a fresh day when the date changes.
    var today: DailyStats {
        let today = Calendar.current.startOfDay(for: Date())
        if !Calendar.current.isDate(stats.date, inSameDayAs: today) {
            self.stats = DailyStats(date: today)
            Self.save(stats)
        }
        return stats
    }

    /// Record the server's lifetime counters from a /status poll. Sets the
    /// day's baselines on first sight and re-baselines after a server
    /// restart (counters drop) or a switch to a different server (port
    /// change). Called on every poll.
    func updateBaselines(completed: Int?, output: Int?, serverPort: Int?) {
        var s = today
        s.updateBaselines(completed: completed, output: output, serverPort: serverPort)
        if s != stats {
            stats = s
            Self.save(stats)
        }
    }

    /// Add one completed request's log metrics to today's running sums.
    /// App-launched servers only (adopted servers have no log to parse).
    func accumulateRequest(ttft: Double?, tps: Double?) {
        guard ttft != nil || tps != nil else { return }
        stats.accumulateRequest(ttft: ttft, tps: tps)
        Self.save(stats)
    }

    /// Reset in-memory stats (tests only).
    func resetForTesting() {
        stats = DailyStats(date: Calendar.current.startOfDay(for: Date()))
    }

    // MARK: - Persistence

    /// Overridable in tests; production always uses Application Support.
    static var statsURLOverride: URL?

    static func statsURL() -> URL {
        if let override = statsURLOverride { return override }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("splashmenubar/stats.json")
    }

    private static func load(for date: Date) -> DailyStats? {
        let url = statsURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let wrapper = try? decoder.decode(StatsWrapper.self, from: data) else { return nil }
        guard Calendar.current.isDate(wrapper.stats.date, inSameDayAs: date) else { return nil }
        return wrapper.stats
    }

    static func save(_ stats: DailyStats) {
        let url = statsURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let wrapper = StatsWrapper(stats: stats)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(wrapper) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct StatsWrapper: Codable {
    let stats: DailyStats
}
