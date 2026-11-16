import Foundation

/// The app's own GitHub releases, and updating the app through Homebrew
/// (`brew upgrade --cask splashmenubar`) when the user confirms.
enum AppUpdater {
    static let repo = "danastott/splashmenubar"
    static let tap = "danastott/tap"
    static let cask = "splashmenubar"

    /// The brew commands the update runs, in order: `brew tap` first
    /// (idempotent, but makes the cask resolvable even for a one-shot
    /// `brew install danastott/tap/splashmenubar` that never tapped it),
    /// `brew trust` (idempotent; Homebrew refuses to load casks from a
    /// tapped-but-untrusted tap, and the prompt can't be answered
    /// non-interactively), then `brew update` so a freshly published cask
    /// version is in the local index.
    static let updateCommands: [[String]] = [
        ["tap", tap],
        ["trust", tap],
        ["update"],
        ["upgrade", "--cask", cask],
    ]

    /// What the progress window shows ($ line, Copy Command).
    static var updateCommandLine: String {
        updateCommands.map { "brew " + $0.joined(separator: " ") }
            .joined(separator: " && ")
    }

    /// Installs the app once for a copy that isn't a Homebrew install yet.
    static var installCommand: String { "brew install \(tap)/\(cask)" }

    /// The running app's version, from the bundle ("1.0.3").
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The newest app release, from this repository's GitHub releases
    /// ("v1.0.3" → "1.0.3"); nil on any network or parse failure.
    static func fetchLatestVersion(timeout: TimeInterval = 5) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
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

    /// The app is a Homebrew install, so a cask upgrade can reach it.
    /// Runs a process: keep it off the main thread.
    static func isInstalledViaHomebrew(brew: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["list", "--cask", cask]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
