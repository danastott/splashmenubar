import Foundation
import AppKit
import SwiftUI

/// The flyout's appearance, from Settings: follow the system, force light,
/// or force dark.
enum UITheme: String, Codable, CaseIterable {
    case system, light, dark

    /// The SwiftUI scheme to force, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System (default)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How a dead splash process died: an exit code or a signal (a signal's
/// number, e.g. 9 for SIGKILL, is what `terminationStatus` holds then).
struct CrashInfo: Equatable {
    let code: Int32
    let bySignal: Bool
    /// Set when the process never started at all (spawn failed); `code` is
    /// meaningless then.
    var note: String? = nil

    var description: String {
        if let note { return note }
        return bySignal ? "killed by signal \(code)" : "exited with code \(code)"
    }
}

enum SplashState: Equatable {
    case stopped
    case starting
    case running
    case crashed(CrashInfo)

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .crashed: return "crashed"
        }
    }
}

/// Parameters for the `splash serve` command line.
struct SplashConfig: Codable, Equatable {
    var model: String
    var port: Int
    var maxMemory: String?      // --max-memory, e.g. "28G"
    var idleRelease: String?    // --idle-release, e.g. "off" (default 10m)
    var maxContext: String?     // --max-context, e.g. "100K"
    var languageOnly: Bool = false      // --language-only
    var kvFormat: String?       // --kv-format: "int8" (default) | "bf16"
    var stateFormat: String?    // --state-format: "fp32" (default) | "bf16"
    var disableANE: Bool = false        // --disable-ane
    var maxCacheDisk: String?   // --max-cache-disk, e.g. "16G" ("0" turns it off)
    var persistentCache: Bool = false   // --persistent-cache
    /// App setting, not a splash flag: seconds between /status polls, i.e.
    /// how often the flyout and menu bar refresh.
    var refreshInterval: Double = 2
    /// App setting, not a splash flag: minutes of generation the tok/s
    /// graph spans.
    var graphMinutes: Int = 5
    /// App setting, not a splash flag: if splash exits on its own, start it
    /// again (up to `SplashProcess.maxAutoRestarts` attempts in a row before
    /// giving up; a manual Start resets the count).
    var autoRestart: Bool = false
    /// App setting, not a splash flag: start `splash serve` when the app
    /// launches. Off by default, so a first launch doesn't download a model
    /// the user never picked; the flyout shows a setup tip instead.
    var startServerOnLaunch: Bool = false
    /// App setting, not a splash flag: start the app (and with it the
    /// server) at login, registered via `SMAppService.mainApp`.
    var launchAtLogin: Bool = false
    /// App setting, not a splash flag: the flyout is pinned open (it comes
    /// back pinned across app restarts).
    var panelPinned: Bool = false
    /// App setting, not a splash flag: where the pinned flyout sits — its
    /// top-left corner (x = left edge, y = top edge in screen coordinates) —
    /// so a restart drops it back where the user dragged it.
    var pinnedPanelTopLeft: PanelTopLeft? = nil
    /// App setting, not a splash flag: the flyout's appearance.
    var theme: UITheme = .system
    /// App setting, not a splash flag: user-picked colors for the flyout's
    /// gauges, by gauge id (tok/prefill/cached/gpu/cpu/mem/graph) as
    /// "#RRGGBB" hex — nil for a gauge = its default color.
    var gaugeColors: [String: String] = [:]

    /// A persisted top-left screen corner.
    struct PanelTopLeft: Codable, Equatable {
        var x: Double
        var y: Double
    }

    static let refreshIntervalChoices: [Double] = [0.5, 1, 2, 5, 10]
    static let graphMinutesChoices: [Int] = [1, 3, 5, 10, 15, 30]
    /// Samples kept for the graph: the longest span at the fastest refresh.
    static let maxGraphSamples = Int(Double(graphMinutesChoices.max()! * 60)
                                     / refreshIntervalChoices.min()!)

    /// How many of the latest samples the graph plots.
    var graphSampleWindow: Int {
        max(2, Int((Double(graphMinutes * 60) / refreshInterval).rounded()))
    }

    static let `default` = SplashConfig(
        model: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M",
        port: 8081,
        maxMemory: nil,
        idleRelease: nil,
        maxContext: nil,
        languageOnly: false,
        kvFormat: nil,
        stateFormat: nil,
        disableANE: false,
        maxCacheDisk: nil,
        persistentCache: false
    )

    init(model: String,
         port: Int,
         maxMemory: String? = nil,
         idleRelease: String? = nil,
         maxContext: String? = nil,
         languageOnly: Bool = false,
         kvFormat: String? = nil,
         stateFormat: String? = nil,
         disableANE: Bool = false,
         maxCacheDisk: String? = nil,
         persistentCache: Bool = false,
         refreshInterval: Double = 2,
         graphMinutes: Int = 5,
         autoRestart: Bool = false,
         startServerOnLaunch: Bool = false,
         launchAtLogin: Bool = false,
         panelPinned: Bool = false,
         pinnedPanelTopLeft: PanelTopLeft? = nil,
         theme: UITheme = .system,
         gaugeColors: [String: String] = [:]) {
        self.model = model
        self.port = port
        self.maxMemory = maxMemory
        self.idleRelease = idleRelease
        self.maxContext = maxContext
        self.languageOnly = languageOnly
        self.kvFormat = kvFormat
        self.stateFormat = stateFormat
        self.disableANE = disableANE
        self.maxCacheDisk = maxCacheDisk
        self.persistentCache = persistentCache
        self.refreshInterval = refreshInterval
        self.graphMinutes = graphMinutes
        self.autoRestart = autoRestart
        self.startServerOnLaunch = startServerOnLaunch
        self.launchAtLogin = launchAtLogin
        self.panelPinned = panelPinned
        self.pinnedPanelTopLeft = pinnedPanelTopLeft
        self.theme = theme
        self.gaugeColors = gaugeColors
    }

    /// Tolerates older/minimal config files: every field beyond model and
    /// port is optional at decode time.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        port = try c.decode(Int.self, forKey: .port)
        maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory)
        idleRelease = try c.decodeIfPresent(String.self, forKey: .idleRelease)
        maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext)
        languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? false
        kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat)
        stateFormat = try c.decodeIfPresent(String.self, forKey: .stateFormat)
        disableANE = try c.decodeIfPresent(Bool.self, forKey: .disableANE) ?? false
        maxCacheDisk = try c.decodeIfPresent(String.self, forKey: .maxCacheDisk)
        persistentCache = try c.decodeIfPresent(Bool.self, forKey: .persistentCache) ?? false
        let interval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 2
        refreshInterval = min(max(interval, 0.25), 60)
        let minutes = try c.decodeIfPresent(Int.self, forKey: .graphMinutes) ?? 5
        graphMinutes = min(max(minutes, 1), Self.graphMinutesChoices.max()!)
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        startServerOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startServerOnLaunch) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        panelPinned = try c.decodeIfPresent(Bool.self, forKey: .panelPinned) ?? false
        pinnedPanelTopLeft = try c.decodeIfPresent(PanelTopLeft.self, forKey: .pinnedPanelTopLeft)
        theme = (try? c.decodeIfPresent(UITheme.self, forKey: .theme)) ?? .system
        gaugeColors = try c.decodeIfPresent([String: String].self, forKey: .gaugeColors) ?? [:]
    }

    /// The user-picked color for a gauge, parsed from its stored hex; nil =
    /// the gauge's default.
    func gaugeColor(id: String) -> Color? {
        guard let hex = gaugeColors[id] else { return nil }
        return Color(hex: hex)
    }

    /// Overridable in tests; production always uses the home directory.
    static var configURLOverride: URL?

    static var configURL: URL {
        configURLOverride ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".splashmenubar.json")
    }

    /// Loads the saved config. A file that can't be read or parsed is
    /// moved aside to `~/.splashmenubar.json.bak` (so it can be inspected
    /// instead of being silently discarded) and `warning` says why the
    /// defaults are in use — the caller surfaces it.
    static func load() -> (config: SplashConfig, warning: String?) {
        guard let data = try? Data(contentsOf: configURL) else {
            return (.default, nil)   // no file yet: first launch
        }
        guard let cfg = try? JSONDecoder().decode(SplashConfig.self, from: data) else {
            quarantineCorruptConfig()
            return (.default,
                    "Saved settings could not be read, so the defaults are in use. "
                    + "The unreadable file was moved to ~/.splashmenubar.json.bak.")
        }
        return (cfg, nil)
    }

    /// Moves an unreadable config out of the way; a newer corrupt file
    /// replaces an older .bak.
    private static func quarantineCorruptConfig() {
        let fm = FileManager.default
        let bak = configURL.deletingPathExtension().appendingPathExtension("json.bak")
        try? fm.removeItem(at: bak)
        try? fm.moveItem(at: configURL, to: bak)
    }

    /// Writes the config to disk (atomically, so a crash mid-write can't
    /// corrupt it). `false` with `saveError` set when it couldn't — the
    /// caller reports that instead of claiming success.
    @discardableResult
    mutating func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: Self.configURL, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// The last write failure, when `save()` returned false.
    private(set) var saveError: String?

    /// The full `splash serve` argument list for this configuration.
    var serveArguments: [String] {
        var args = ["splash", "serve", "--model", model, "--port", String(port)]
        if let v = clean(maxMemory) { args += ["--max-memory", v] }
        if let v = clean(idleRelease) { args += ["--idle-release", v] }
        if let v = clean(maxContext) { args += ["--max-context", v] }
        if languageOnly { args.append("--language-only") }
        if let v = clean(kvFormat) { args += ["--kv-format", v] }
        if let v = clean(stateFormat) { args += ["--state-format", v] }
        if disableANE { args.append("--disable-ane") }
        if let v = clean(maxCacheDisk) { args += ["--max-cache-disk", v] }
        if persistentCache { args.append("--persistent-cache") }
        return args
    }

    private func clean(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension Color {
    /// Parses "#RRGGBB" (case-insensitive); nil for anything else.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB (non-sRGB colors are converted, not rejected).
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// Owns the `splash serve` child process and streams its output lines.
/// Output is read with FileHandle readability handlers (see OutputReader)
/// and lines are dispatched to the main thread.
final class SplashProcess {
    private(set) var state: SplashState = .stopped
    private var proc: Process?
    /// True while the app's own `splash serve` child is running (so quitting
    /// the app stops it).
    var ownsRunningChild: Bool { proc?.isRunning ?? false }
    private var readers: [OutputReader] = []
    private var intentionalStop = false
    private var pendingRestart = false
    private var lastConfig = SplashConfig.default
    /// Bumped on every start; output still arriving from an older child is
    /// dropped instead of being attributed to the new one.
    private var generation = 0
    /// Set while restart(with:) waits for an external server to exit before
    /// starting ours; Stop clears it so that start never happens.
    private var externalRestartToken: UUID?
    /// Unexpected exits in a row that auto-restart is covering; a manual
    /// start resets it.
    private var autoRestartStreak = 0
    /// Set while an auto-restart is waiting; Stop or Start clears it so the
    /// pending start never happens.
    private var autoRestartToken: UUID?
    /// True while a crashed server is about to auto-restart (the app uses
    /// this to stay quiet instead of notifying).
    var autoRestartScheduled: Bool { autoRestartToken != nil }
    /// Consecutive unexpected exits auto-restart tolerates before giving up.
    static let maxAutoRestarts = 3

    /// Called on the main thread, once per output line (stdout or stderr).
    var onLine: ((String) -> Void)?
    /// Called on the main thread.
    var onState: ((SplashState) -> Void)?

    func start(_ config: SplashConfig, manual: Bool = true) {
        guard proc == nil else { return }
        externalRestartToken = nil
        autoRestartToken = nil
        if manual { autoRestartStreak = 0 }
        lastConfig = config
        intentionalStop = false
        generation += 1
        let gen = generation
        setState(.starting)

        let p = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = config.serveArguments
        var env = Self.childEnvironment()
        // huggingface_hub hides its download progress bars when stderr is not
        // a TTY; -1 forces them on so the app can show download progress.
        env["TQDM_POSITION"] = "-1"
        p.environment = env
        p.standardOutput = stdout
        p.standardError = stderr
        p.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.proc === finished else { return }
                self.teardown()
                let restart = self.pendingRestart
                self.pendingRestart = false
                if restart {
                    // A user-initiated restart: start the new child (with the
                    // config restart(with:) already stored in lastConfig),
                    // even though this one was killed on purpose.
                    self.start(self.lastConfig)
                    return
                }
                if self.intentionalStop {
                    self.setState(.stopped)
                    return
                }
                // For a process killed by a signal, terminationStatus holds
                // the signal number (15 = SIGTERM, 9 = SIGKILL), not a code.
                let info = CrashInfo(code: finished.terminationStatus,
                                     bySignal: finished.terminationReason == .uncaughtSignal)
                self.setState(.crashed(info))
                if self.lastConfig.autoRestart,
                   self.autoRestartStreak < Self.maxAutoRestarts {
                    self.maybeScheduleAutoRestart()
                }
            }
        }
        self.proc = p
        do {
            try p.run()
        } catch {
            self.proc = nil
            self.setState(.crashed(CrashInfo(code: -1, bySignal: false,
                                             note: "couldn't launch: \(error.localizedDescription)")))
            return
        }

        readers = [stdout, stderr].map { pipe in
            OutputReader(handle: pipe.fileHandleForReading) { [weak self] line in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.onLine?(line)
                }
            }
        }
        setState(.running)
    }

    /// Schedules an auto-restart, first re-checking the port: when a splash
    /// we didn't start is serving it, the child died with "address in use"
    /// and spawning would only crash-loop behind the healthy external
    /// server — the app adopts it instead (the flyout shows the "external"
    /// chip). The token is held across the probe so a Stop in the meantime
    /// cancels the restart, as it does for the 2 s delay.
    private func maybeScheduleAutoRestart() {
        let token = UUID()
        autoRestartToken = token
        Task { @MainActor [weak self] in
            guard let self, self.autoRestartToken == token,
                  self.proc == nil, !self.intentionalStop
            else { return }
            if await StatusClient.fetch(port: self.lastConfig.port, timeout: 1) != nil {
                self.autoRestartToken = nil
                return
            }
            self.scheduleAutoRestart(with: token)
        }
    }

    /// After an unexpected exit (with auto-restart on), wait briefly and
    /// start again. Bails if Stop/Start happened in the meantime; gives up
    /// after `maxAutoRestarts` consecutive crashes — only a manual start
    /// resets the streak.
    private func scheduleAutoRestart(with token: UUID) {
        autoRestartStreak += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.autoRestartToken == token,
                  self.proc == nil, !self.intentionalStop
            else { return }
            self.autoRestartToken = nil
            self.start(self.lastConfig, manual: false)
        }
    }

    /// Port of an adopted splash the app didn't start, when it differs from
    /// the configured port (found by `discoverServerPorts`). Stop and
    /// Restart act on it instead of the configured port.
    var externalPort: Int?

    /// Stop the splash server on our port: our child if we have one,
    /// otherwise a splash server started outside the app (UI "Stop"). Also
    /// cancels a restart in progress.
    func stop() {
        pendingRestart = false
        if autoRestartToken != nil {
            // A crashed server is about to restart itself; cancel that and
            // settle into the stopped state.
            autoRestartToken = nil
            setState(.stopped)
            return
        }
        if externalRestartToken != nil {
            externalRestartToken = nil
            setState(.stopped)
        }
        if proc != nil {
            stopOwnChild()
            return
        }
        // No child of ours: shut down a splash serving the port (started
        // outside the app, or left over). Never anything that isn't splash.
        stopExternalServer(on: externalPort ?? lastConfig.port)
    }

    /// SIGTERM our child and the engine under it, SIGKILL whatever is left
    /// after 5 s. The termination handler then updates the state.
    private func stopOwnChild() {
        guard let p = proc else { return }
        intentionalStop = true
        // Already exited: its termination handler is queued and finishes up.
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        // Collect the engine before the wrapper exits and it is reparented.
        let tree = Self.descendants(of: pid)
        p.terminate()
        for child in tree { kill(child, SIGTERM) }
        DispatchQueue.global(qos: .utility).async {
            Self.killAfterGrace([pid] + tree, grace: 5)
        }
    }

    /// Used on app quit: stop our own child and its engine, waiting (briefly)
    /// until they're gone so nothing is orphaned holding the model in memory.
    /// Never touches an externally started server.
    func stopChildBeforeQuit() {
        guard let p = proc, p.isRunning else { return }
        intentionalStop = true
        let pid = p.processIdentifier
        let pids = [pid] + Self.descendants(of: pid)
        for each in pids { kill(each, SIGTERM) }
        Self.killAfterGrace(pids, grace: 3)
    }

    private func stopExternalServer(on port: Int) {
        let pids = Self.findServerPIDs(port: port)
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .utility).async {
            Self.killAfterGrace(pids, grace: 5)
        }
    }

    /// Blocks until every pid has exited or `grace` seconds pass, then
    /// SIGKILLs the survivors — re-identified first, so a pid that was
    /// reused by an unrelated process in the meantime is left alone.
    private static func killAfterGrace(_ pids: [pid_t], grace: TimeInterval) {
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in pids where kill(pid, 0) == 0 && isSplashProcess(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// PIDs of the splash server listening on `port` and its child processes
    /// (the `serve-native` engine). A listener that isn't splash, such as
    /// another app using the port, is never included.
    /// TCP ports that splash processes are listening on, on any port — for
    /// finding a splash started outside the app (e.g. `splash serve` in a
    /// terminal) without knowing its port. Blocking (runs lsof and ps), so
    /// call it off the main thread; callers confirm each port with a
    /// /status probe, since the engine may listen on internal ports too.
    static func discoverServerPorts() -> [Int] {
        // -F: one field per line: "p<pid>", then "n<address:port>" per socket.
        guard let out = runCapture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        else { return [] }
        var portsByPID: [pid_t: Set<Int>] = [:]
        var pid: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let pid,
                      let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) {
                portsByPID[pid, default: []].insert(port)
            }
        }
        guard !portsByPID.isEmpty else { return [] }
        let list = portsByPID.keys.map(String.init).joined(separator: ",")
        guard let ps = runCapture("/bin/ps", ["-o", "pid=,args=", "-p", list]) else { return [] }
        var ports = Set<Int>()
        for row in ps.split(separator: "\n") {
            let parts = row.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let p = pid_t(parts[0]),
                  isSplashCommandLine(parts[1]) else { continue }
            ports.formUnion(portsByPID[p] ?? [])
        }
        return ports.sorted()
    }

    static func findServerPIDs(port: Int) -> [pid_t] {
        var pids = Set<pid_t>()
        for pid in pidList(runCapture("/usr/sbin/lsof", ["-tiTCP:\(port)", "-sTCP:LISTEN"]))
        where isSplashProcess(pid) {
            pids.insert(pid)
            pids.formUnion(descendants(of: pid))
        }
        return Array(pids)
    }

    /// True if the process's command line is splash's. The engine binary is
    /// named `splash`, and the Python server runs from inside the splash
    /// install (Homebrew Cellar, a pipx venv, …), so a path token counts
    /// when `splash` is a whole path component: `…/Cellar/splash/…/python3`,
    /// `…/engine/splash`. A bare substring never matches, so e.g.
    /// `~/projects/splashy/train.py` is left alone.
    private static func isSplashProcess(_ pid: pid_t) -> Bool {
        guard let args = runCapture("/bin/ps", ["-o", "args=", "-p", "\(pid)"]) else { return false }
        return isSplashCommandLine(args)
    }

    /// True if a command line is splash's: `splash` as a whole word or path
    /// component (`splash serve`, `…/engine/splash serve-native`,
    /// `…/Cellar/splash/…/python3 -m server.server`) — not merely containing
    /// it (`java -splash:icon.gif`, `…/splashmenubar/…`).
    static func isSplashCommandLine(_ args: String) -> Bool {
        for token in args.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token == "splash" || token.hasSuffix("/splash") || token.contains("/splash/") {
                return true
            }
        }
        return false
    }

    /// All processes below `pid`, children first.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast(), out.count < 64 {
            let kids = pidList(runCapture("/usr/bin/pgrep", ["-P", "\(next)"]))
            out += kids
            queue += kids
        }
        return out
    }

    private static func pidList(_ output: String?) -> [pid_t] {
        (output ?? "").split(separator: "\n").compactMap {
            Int32($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func runCapture(_ launchPath: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Stops whatever serves splash now and starts it with `config` (which
    /// may name a different model or port than the running server).
    func restart(with config: SplashConfig) {
        // Our own child: stop it; the termination handler starts lastConfig.
        if proc != nil {
            lastConfig = config
            pendingRestart = true
            stopOwnChild()
            return
        }

        // No child of ours, but a splash started elsewhere (or one left over
        // from an earlier run of the app) may hold the old or the new port.
        // Only splash processes are stopped; if something else holds the new
        // port, splash fails to start and the crash card says why.
        let oldPorts = Set([lastConfig.port, config.port] + (externalPort.map { [$0] } ?? []))
        lastConfig = config
        externalPort = nil
        var pids = Set<pid_t>()
        for port in oldPorts { pids.formUnion(Self.findServerPIDs(port: port)) }
        guard !pids.isEmpty else {
            start(config)
            return
        }
        let token = UUID()
        externalRestartToken = token
        setState(.starting)
        for pid in pids { kill(pid, SIGTERM) }
        let all = Array(pids)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Give it 5 s to exit cleanly, then force it, then start ours.
            Self.killAfterGrace(all, grace: 5)
            Thread.sleep(forTimeInterval: 0.5)   // let the port free up
            DispatchQueue.main.async {
                // Stop (or a fresh Start) while waiting cancels this start.
                guard let self, self.externalRestartToken == token, self.proc == nil else { return }
                self.externalRestartToken = nil
                self.start(self.lastConfig)
            }
        }
    }

    /// Removes terminal escape sequences (colors, cursor moves between
    /// stacked progress bars).
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(
            of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression
        )
    }

    private func teardown() {
        // Let the readers drain what the child wrote just before exiting (its
        // final error line), then stop them. They also stop by themselves at
        // EOF; the engine can outlive the wrapper and hold the pipes open.
        let old = readers
        readers.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            old.forEach { $0.cancel() }
        }
        proc = nil
    }

    private func setState(_ s: SplashState) {
        state = s
        onState?(s)
    }

    /// Apps launched via LaunchServices (Finder, `open`) get a minimal PATH
    /// that excludes Homebrew, so prepend the usual user tool locations.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for extra in ["/opt/homebrew/bin", "/usr/local/bin",
                      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        where !path.components(separatedBy: ":").contains(extra) {
            path = extra + ":" + path
        }
        env["PATH"] = path
        return env
    }
}

/// Splits one pipe's output into lines. Uses a readability handler rather
/// than a thread blocked in `availableData`, so it can be stopped and its
/// handle closed safely at any time; a final line without a newline is still
/// delivered at EOF or on cancel.
final class OutputReader {
    private let handle: FileHandle
    private let onLine: (String) -> Void
    private let lock = NSLock()
    private var pending = Data()
    private var done = false

    init(handle: FileHandle, onLine: @escaping (String) -> Void) {
        self.handle = handle
        self.onLine = onLine
        handle.readabilityHandler = { [weak self] h in
            self?.read(from: h)
        }
    }

    private func read(from h: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        let chunk = h.availableData
        if chunk.isEmpty {
            finishLocked()   // EOF
            return
        }
        pending.append(chunk)
        let split = Self.splitLines(pending)
        pending = split.rest
        for line in split.lines { emit(line) }
    }

    /// Splits `data` into complete lines and the tail still waiting for its
    /// terminator. A bare \r counts as a terminator too: progress bars
    /// (tqdm, used for model downloads) redraw with \r and no \n. A line
    /// boundary can never fall inside a multibyte UTF-8 character (neither
    /// 0x0A nor 0x0D occurs in one), so a character split across pipe
    /// chunks stays in `rest` until its remaining bytes arrive; only an
    /// unterminated tail at EOF degrades to a replacement glyph.
    static func splitLines(_ data: Data) -> (lines: [Data], rest: Data) {
        var lines: [Data] = []
        var rest = data
        while let nl = rest.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = Data(rest[rest.startIndex..<nl])
            rest = Data(rest[rest.index(after: nl)...])
            lines.append(line)
        }
        return (lines, rest)
    }

    /// Stops reading, delivers any unterminated last line, closes the handle.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func finishLocked() {
        guard !done else { return }
        done = true
        handle.readabilityHandler = nil
        if !pending.isEmpty {
            emit(pending)
            pending.removeAll()
        }
        try? handle.close()
    }

    private func emit(_ data: Data) {
        let line = SplashProcess.stripANSI(String(decoding: data, as: UTF8.self))
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return }
        onLine(line)
    }
}
