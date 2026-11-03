import Foundation

enum SplashState: Equatable {
    case stopped
    case starting
    case running
    case crashed(Int32)

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .crashed(let c): return "crashed (\(c))"
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
         graphMinutes: Int = 5) {
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
    }

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".splashmenubar.json")
    }

    static func load() -> SplashConfig {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(SplashConfig.self, from: data) {
            return cfg
        }
        return .default
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.configURL)
    }

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

    /// Called on the main thread, once per output line (stdout or stderr).
    var onLine: ((String) -> Void)?
    /// Called on the main thread.
    var onState: ((SplashState) -> Void)?

    func start(_ config: SplashConfig) {
        guard proc == nil else { return }
        externalRestartToken = nil
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
                self.setState(self.intentionalStop ? .stopped : .crashed(finished.terminationStatus))
                if restart { self.start(self.lastConfig) }
            }
        }
        self.proc = p
        do {
            try p.run()
        } catch {
            self.proc = nil
            self.setState(.crashed(-1))
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

    /// Stop the splash server on our port: our child if we have one,
    /// otherwise a splash server started outside the app (UI "Stop"). Also
    /// cancels a restart in progress.
    func stop() {
        pendingRestart = false
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
        stopExternalServer(on: lastConfig.port)
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
    /// SIGKILLs the survivors.
    private static func killAfterGrace(_ pids: [pid_t], grace: TimeInterval) {
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    /// PIDs of the splash server listening on `port` and its child processes
    /// (the `serve-native` engine). A listener that isn't splash, such as
    /// another app using the port, is never included.
    static func findServerPIDs(port: Int) -> [pid_t] {
        var pids = Set<pid_t>()
        for pid in pidList(runCapture("/usr/sbin/lsof", ["-tiTCP:\(port)", "-sTCP:LISTEN"]))
        where isSplashProcess(pid) {
            pids.insert(pid)
            pids.formUnion(descendants(of: pid))
        }
        return Array(pids)
    }

    /// True if the process's command line is splash's (its Python server
    /// lives under the splash install, and the engine is `splash serve-native`).
    private static func isSplashProcess(_ pid: pid_t) -> Bool {
        guard let args = runCapture("/bin/ps", ["-o", "args=", "-p", "\(pid)"]) else { return false }
        return args.lowercased().contains("splash")
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
        let oldPort = lastConfig.port
        lastConfig = config
        var pids = Set(Self.findServerPIDs(port: oldPort))
        if config.port != oldPort { pids.formUnion(Self.findServerPIDs(port: config.port)) }
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
private final class OutputReader {
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
        // Progress bars (tqdm, used for model downloads) redraw with a bare
        // \r and no \n, so treat \r as a line end as well.
        while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            emit(lineData)
        }
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
