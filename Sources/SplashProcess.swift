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
/// Output is read on dedicated background threads (blocking `availableData`
/// loops) and lines are dispatched to the main thread.
final class SplashProcess {
    private(set) var state: SplashState = .stopped
    private var proc: Process?
    /// True while the app's own `splash serve` child is running (so quitting
    /// the app stops it).
    var ownsRunningChild: Bool { proc?.isRunning ?? false }
    private var readerThreads: [Thread] = []
    private var readerHandles: [FileHandle] = []
    private var intentionalStop = false
    private var pendingRestart = false
    private var lastConfig = SplashConfig.default

    /// Called on the main thread, once per output line (stdout or stderr).
    var onLine: ((String) -> Void)?
    /// Called on the main thread.
    var onState: ((SplashState) -> Void)?

    func start(_ config: SplashConfig) {
        guard proc == nil else { return }
        lastConfig = config
        intentionalStop = false
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

        readerHandles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        startReader(handle: stdout.fileHandleForReading, label: "stdout")
        startReader(handle: stderr.fileHandleForReading, label: "stderr")
        setState(.running)
    }

    /// Stop the splash server on our port: our child if we have one,
    /// otherwise the external process serving the port (UI "Stop").
    func stop() {
        if let p = proc, p.isRunning {
            intentionalStop = true
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.intentionalStop,
                      let p = self.proc, p.isRunning, p.processIdentifier == pid else { return }
                kill(pid, SIGKILL)
            }
            return
        }
        if proc != nil {
            teardown()
            return
        }
        // No child of ours: shut down whatever is serving the port (a splash
        // started outside the app, or a leftover process).
        stopExternalServer(on: lastConfig.port)
    }

    /// Stop only our own child (used on app quit; never touches an
    /// externally started server).
    func stopChild() {
        guard let p = proc, p.isRunning else { return }
        intentionalStop = true
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.intentionalStop,
                  let p = self.proc, p.isRunning, p.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    private func stopExternalServer(on port: Int) {
        let pids = Self.findServerPIDs(port: port)
        for pid in pids { kill(pid, SIGTERM) }
        guard !pids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            for pid in pids where kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// PIDs that belong to the splash server on `port`: the listener
    /// (Python wrapper) plus the native engine, which can outlive it.
    static func findServerPIDs(port: Int) -> [pid_t] {
        var pids = Set<pid_t>()
        if let out = runCapture("/usr/sbin/lsof", ["-tiTCP:\(port)", "-sTCP:LISTEN"]) {
            for line in out.split(separator: "\n") {
                if let v = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pids.insert(v)
                }
            }
        }
        if let out = runCapture("/usr/bin/pgrep", ["-f", "serve-native.*--port \(port)( |$)"]) {
            for line in out.split(separator: "\n") {
                if let v = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pids.insert(v)
                }
            }
        }
        return Array(pids)
    }

    private static func runCapture(_ launchPath: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Stops whatever serves splash now and starts it with `config` (which
    /// may name a different model or port than the running server).
    func restart(with config: SplashConfig) {
        // Our own child: stop it; the termination handler starts lastConfig.
        if let p = proc, p.isRunning {
            lastConfig = config
            pendingRestart = true
            stop()
            return
        }
        if proc != nil { teardown() }

        // No child of ours, but a server started elsewhere (or one left over
        // from an earlier run of the app) may hold the old or the new port.
        let oldPort = lastConfig.port
        lastConfig = config
        let pids = Set(Self.findServerPIDs(port: oldPort) + Self.findServerPIDs(port: config.port))
        guard !pids.isEmpty else {
            start(config)
            return
        }
        setState(.starting)
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Give it 5 s to exit cleanly, then force it, then start ours.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
                Thread.sleep(forTimeInterval: 0.2)
            }
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.5)   // let the port free up
            DispatchQueue.main.async {
                guard let self, self.proc == nil else { return }
                self.start(self.lastConfig)
            }
        }
    }

    // MARK: - Reading

    private func startReader(handle: FileHandle, label: String) {
        let thread = Thread { [weak self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF
                pending.append(chunk)
                // Progress bars (tqdm, used for model downloads) redraw with
                // a bare \r and no \n, so treat \r as a line end as well.
                while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    let line = Self.stripANSI(String(decoding: lineData, as: UTF8.self))
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    DispatchQueue.main.async {
                        self?.onLine?(line)
                    }
                }
            }
        }
        thread.name = "splash-\(label)-reader"
        thread.stackSize = 512 * 1024
        thread.start()
        readerThreads.append(thread)
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
        // Closing the handles unblocks any reader threads in availableData.
        for h in readerHandles {
            try? h.close()
        }
        readerHandles.removeAll()
        readerThreads.removeAll()
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
