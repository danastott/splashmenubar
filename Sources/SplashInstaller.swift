import AppKit
import SwiftUI

/// Detects whether the `splash` CLI is available and installs it through
/// Homebrew (`brew install incoai/tap/splash`) when the user authorizes it.
enum SplashInstaller {
    static let formula = "incoai/tap/splash"
    static var installCommand: String { "brew install \(formula)" }

    /// The same PATH the `splash serve` child gets (Homebrew and ~/.local/bin
    /// prepended), so detection matches what will actually be launched.
    static var searchPath: [String] {
        (SplashProcess.childEnvironment()["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in searchPath where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isSplashInstalled: Bool { locate("splash") != nil }
    static var brewPath: String? { locate("brew") }

    /// The python3 interpreter bundled with the installed splash (next to
    /// its libexec), nil when splash isn't installed or the interpreter is
    /// missing. Runs no process.
    static func pythonPath() -> String? {
        guard let splash = locate("splash") else { return nil }
        let fm = FileManager.default
        let resolved = URL(fileURLWithPath: splash).resolvingSymlinksInPath()
        // <prefix>/bin/splash → <prefix>/libexec/python/bin/python3.
        let prefix = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = prefix.appendingPathComponent("libexec/python/bin/python3")
        return fm.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    /// Version of the `splash` on the PATH ("Splash 1.6.0" → "1.6.0");
    /// nil when splash isn't installed. Runs a process: keep it off the
    /// main thread.
    static func installedVersion() -> String? {
        guard let splash = locate("splash") else { return nil }
        return SplashProcess.versionString(SplashProcess.runCapture(splash, ["--version"]))
    }

    /// Newest splash release, from the GitHub releases the Homebrew
    /// formula tracks (nil on any network or parse failure).
    static func fetchLatestVersion(timeout: TimeInterval = 5) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/incoai/splash/releases/latest")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("SplashMenuBar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            struct Release: Decodable { let tag_name: String? }
            guard var tag = try JSONDecoder().decode(Release.self, from: data).tag_name else {
                return nil
            }
            if tag.hasPrefix("v") { tag.removeFirst() }   // tolerate v-prefixed tags
            return tag
        } catch {
            return nil
        }
    }
}

/// Splash version strings as `splash --version` and release tags report
/// them ("1.6.0"), compared segment by segment: numerically where both
/// sides are numbers, as strings otherwise.
enum SplashVersion {
    static func isNewer(_ a: String, over b: String) -> Bool {
        let sa = a.split(separator: ".", omittingEmptySubsequences: false)
        let sb = b.split(separator: ".", omittingEmptySubsequences: false)
        for i in 0..<max(sa.count, sb.count) {
            let x = i < sa.count ? sa[i] : ""
            let y = i < sb.count ? sb[i] : ""
            if x == y { continue }
            if let nx = Int(x), let ny = Int(y) { return nx > ny }
            return String(x) > String(y)
        }
        return false
    }
}

// MARK: - Install progress window

final class InstallModel: ObservableObject {
    enum Phase: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    @Published var phase: Phase = .running
    @Published var output: String = ""
    /// True once `brew install` has been silent for a while — no error,
    /// just no output (a stalled network, or an Xcode license prompt brew
    /// can't show). The view shows a hint; the run keeps going.
    @Published var stalled = false

    private var proc: Process?
    private var cancelled = false
    private var lastOutputAt = Date()
    private var stallTimer: Timer?
    /// How long without output counts as a stall.
    private let stallAfter: TimeInterval = 5 * 60

    /// What the window is running; drives the wording and the success
    /// check.
    enum Job: Equatable {
        case installSplash
        case upgradeSplash
        case updateApp
    }
    var job: Job = .installSplash

    /// The command(s) the window shows ($ line, Copy Command).
    var commandLine: String = SplashInstaller.installCommand

    var runningTitle: String {
        switch job {
        case .installSplash: return "Installing splash with Homebrew…"
        case .upgradeSplash: return "Updating splash with Homebrew…"
        case .updateApp: return "Updating Splash Menu Bar with Homebrew…"
        }
    }

    var doneTitle: String {
        switch job {
        case .installSplash: return "splash is installed"
        case .upgradeSplash: return "splash is updated"
        case .updateApp: return "Splash Menu Bar is updated"
        }
    }

    /// The brew commands still to run, after the one launched (head = next).
    private var pendingCommands: [[String]] = []

    /// Runs the job's brew command(s) with stdin closed so they can never
    /// block on a prompt. Install additionally requires `splash` on the
    /// PATH at the end; a clean exit of the last command suffices for the
    /// rest.
    func start(brew: String) {
        let commands: [[String]]
        switch job {
        case .installSplash:
            commands = [["install", SplashInstaller.formula]]
        case .upgradeSplash:
            commands = [["upgrade", SplashInstaller.formula]]
        case .updateApp:
            commands = AppUpdater.updateCommands
        }
        commandLine = commands.map { "brew " + $0.joined(separator: " ") }
            .joined(separator: " && ")
        pendingCommands = Array(commands.dropFirst())
        output = "$ \(commandLine)\n"
        phase = .running
        stalled = false
        lastOutputAt = Date()
        launch(brew: brew, args: commands[0])
    }

    /// Spawns one brew invocation; the termination handler starts the next
    /// pending command or finishes the run.
    private func launch(brew: String, args: [String]) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        var env = SplashProcess.childEnvironment()
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_COLOR"] = nil
        env["HOMEBREW_NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.output += text
                self?.lastOutputAt = Date()
                self?.stalled = false
            }
        }
        p.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopStallTimer()
                self.proc = nil
                if self.cancelled {
                    self.phase = .failed(self.job == .installSplash
                                         ? "Installation cancelled." : "Update cancelled.")
                } else if finished.terminationStatus == 0 {
                    if let next = self.pendingCommands.first {
                        self.pendingCommands.removeFirst()
                        self.output += "\n$ brew \(next.joined(separator: " "))\n"
                        self.launch(brew: brew, args: next)
                    } else if self.job == .installSplash,
                              !SplashInstaller.isSplashInstalled {
                        self.phase = .failed("Homebrew finished, but `splash` still isn't on the PATH.")
                    } else {
                        self.phase = .succeeded
                    }
                } else {
                    self.phase = .failed("brew exited with status \(finished.terminationStatus).")
                }
            }
        }

        proc = p
        do {
            try p.run()
            startStallTimer()
        } catch {
            proc = nil
            phase = .failed("Couldn't launch Homebrew: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard let p = proc, p.isRunning else { return }
        cancelled = true
        p.terminate()
    }

    /// While the install runs, note it when brew has printed nothing for a
    /// long time — the usual causes are a stalled network or an Xcode
    /// license brew can't prompt for non-interactively.
    private func startStallTimer() {
        stopStallTimer()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.phase == .running else { return }
            if Date().timeIntervalSince(self.lastOutputAt) >= self.stallAfter {
                self.stalled = true
            }
        }
    }

    private func stopStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
    }
}

struct InstallView: View {
    @ObservedObject var model: InstallModel
    let onFinish: (_ installed: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                switch model.phase {
                case .running:
                    ProgressView().controlSize(.small)
                    Text(model.runningTitle).font(.headline)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(model.doneTitle).font(.headline)
                case .failed(let reason):
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text(reason).font(.headline)
                }
            }

            if model.stalled {
                Text("No output for 5 minutes — brew may be waiting on the network, or on an Xcode license it can't ask for (run `sudo xcodebuild -license accept` in Terminal). The run keeps going; Cancel if it never finishes.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            ScrollViewReader { reader in
                ScrollView {
                    Text(model.output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("log")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: model.output) { _ in
                    reader.scrollTo("log", anchor: .bottom)
                }
            }

            HStack {
                if case .failed = model.phase {
                    Button("Copy Command") { copyCommand(model.commandLine) }
                }
                Spacer()
                switch model.phase {
                case .running:
                    Button("Cancel") { model.cancel() }
                case .succeeded:
                    Button(model.job == .installSplash ? "Start Splash" : "Done") { onFinish(true) }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { onFinish(false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 360)
    }
}

func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
}
