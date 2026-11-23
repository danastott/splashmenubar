import AppKit
import SwiftUI

/// The "Recent requests" window: the finished requests from the server's
/// log (servers this app started), newest first. An adopted (external)
/// server has no log, so its window shows the empty state.
struct RequestLogView: View {
    @ObservedObject var store: MetricsStore

    /// The newest 200 finished requests (a "Done" log line, not the
    /// "Started" one), newest first.
    private var rows: [RequestMetrics] {
        Array(store.requests.reversed()
                .filter { !$0.isStarted }
                .prefix(200))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    header
                    table
                }
            }
        }
        .frame(width: 600, height: 440)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No finished requests yet.")
                .font(.system(size: 12, weight: .semibold))
            Text("Requests served by a server this app started appear here as they finish; a server started outside the app has no log for the app to read.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("\(rows.count) finished")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Finished requests from this server's log; the newest 200 are listed.")
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Time") { r in
                Text(Self.timeFormatter.string(from: r.timestamp))
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(64)
            TableColumn("Input") { r in
                Text(Fmt.int(r.input))
                    .font(.system(size: 11).monospacedDigit())
            }
            .width(min: 56, ideal: 56)
            TableColumn("Cached") { r in
                Text(Fmt.int(r.cached))
                    .font(.system(size: 11).monospacedDigit())
            }
            .width(min: 56, ideal: 56)
            TableColumn("Output") { r in
                Text(Fmt.int(r.output))
                    .font(.system(size: 11).monospacedDigit())
            }
            .width(min: 56, ideal: 56)
            TableColumn("TTFT") { r in
                Text(Fmt.seconds(r.ttftSeconds))
                    .font(.system(size: 11).monospacedDigit())
            }
            .width(min: 64, ideal: 64)
            TableColumn("tok/s") { r in
                Text(Fmt.double(r.tokensPerSecond))
                    .font(.system(size: 11).monospacedDigit())
            }
            .width(min: 56, ideal: 56)
        }
    }
}
