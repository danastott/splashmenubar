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

    /// Runs `brew install` with stdin closed so it can never block on a prompt.
    func start(brew: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install", SplashInstaller.formula]
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
                    self.phase = .failed("Installation cancelled.")
                } else if finished.terminationStatus == 0 && SplashInstaller.isSplashInstalled {
                    self.phase = .succeeded
                } else if finished.terminationStatus == 0 {
                    self.phase = .failed("Homebrew finished, but `splash` still isn't on the PATH.")
                } else {
                    self.phase = .failed("brew exited with status \(finished.terminationStatus).")
                }
            }
        }

        output = "$ \(SplashInstaller.installCommand)\n"
        phase = .running
        stalled = false
        lastOutputAt = Date()
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
                    Text("Installing splash with Homebrew…").font(.headline)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("splash is installed").font(.headline)
                case .failed(let reason):
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text(reason).font(.headline)
                }
            }

            if model.stalled {
                Text("No output for 5 minutes — brew may be waiting on the network, or on an Xcode license it can't ask for (run `sudo xcodebuild -license accept` in Terminal). The install keeps running; Cancel if it never finishes.")
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
                    Button("Copy Command") { copyInstallCommand() }
                }
                Spacer()
                switch model.phase {
                case .running:
                    Button("Cancel") { model.cancel() }
                case .succeeded:
                    Button("Start Splash") { onFinish(true) }
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

func copyInstallCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(SplashInstaller.installCommand, forType: .string)
}
