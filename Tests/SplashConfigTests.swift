import XCTest
@testable import SplashMenuBar

/// The app-side config fields (persistence round-trip and legacy files),
/// the download flag that gates the "model ready" notification, the
/// Hugging Face cache lookup the Finder links use, and SettingsModel's
/// "reset to defaults".
final class SplashConfigTests: XCTestCase {
    func testNewAppFieldsRoundTrip() throws {
        var c = SplashConfig.default
        c.launchAtLogin = true
        c.startServerOnLaunch = true
        c.panelPinned = true
        c.pinnedPanelTopLeft = SplashConfig.PanelTopLeft(x: 123.5, y: 640.0)
        let data = try JSONEncoder().encode(c)
        let d = try JSONDecoder().decode(SplashConfig.self, from: data)
        XCTAssertEqual(d, c)
    }

    /// A config file written before these fields existed must still load,
    /// with the new fields at their defaults.
    func testLegacyConfigFileStillDecodes() throws {
        let legacy = """
        {
          "model": "owner/repo:V",
          "port": 9000,
          "refreshInterval": 1
        }
        """
        let c = try JSONDecoder().decode(SplashConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(c.model, "owner/repo:V")
        XCTAssertEqual(c.port, 9000)
        XCTAssertEqual(c.refreshInterval, 1)
        XCTAssertFalse(c.autoRestart)
        XCTAssertFalse(c.launchAtLogin)
        // Files from before the option existed load with it off.
        XCTAssertFalse(c.startServerOnLaunch)
        XCTAssertFalse(c.panelPinned)
        XCTAssertNil(c.pinnedPanelTopLeft)
    }

    /// Appearance and gauge colors persist, and a file written before they
    /// existed still decodes to their defaults.
    func testThemeAndGaugeColorsRoundTrip() throws {
        var c = SplashConfig.default
        c.theme = .dark
        c.gaugeColors = ["tok": "#FF0000", "graph": "#00FF00"]
        let d = try JSONDecoder().decode(SplashConfig.self,
                                         from: JSONEncoder().encode(c))
        XCTAssertEqual(d, c)
        let old = try JSONDecoder().decode(SplashConfig.self,
                                           from: Data(#"{"model":"m","port":1}"#.utf8))
        XCTAssertEqual(old.theme, .system)
        XCTAssertTrue(old.gaugeColors.isEmpty)
    }

    /// A corrupt config file is moved aside as .bak (not silently discarded)
    /// with a warning, and the defaults are used.
    func testLoadQuarantinesCorruptConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashmb-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        SplashConfig.configURLOverride = dir.appendingPathComponent(".splashmenubar.json")
        defer { SplashConfig.configURLOverride = nil }

        try "{ not json".write(to: SplashConfig.configURL, atomically: true, encoding: .utf8)
        let loaded = SplashConfig.load()
        XCTAssertEqual(loaded.config, .default)
        XCTAssertNotNil(loaded.warning)
        let bak = SplashConfig.configURL.deletingPathExtension()
            .appendingPathExtension("json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SplashConfig.configURL.path))
    }

    /// save() reports a failed write (instead of claiming success) and a
    /// successful one round-trips through load() — theme and colors included.
    func testSaveFailureAndRoundTrip() throws {
        SplashConfig.configURLOverride = URL(fileURLWithPath: "/nonexistent-splashmb-dir/x.json")
        defer { SplashConfig.configURLOverride = nil }
        var c = SplashConfig.default
        c.theme = .light
        c.gaugeColors = ["mem": "#0000FF"]
        XCTAssertFalse(c.save())
        XCTAssertNotNil(c.saveError)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashmb-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        SplashConfig.configURLOverride = dir.appendingPathComponent(".splashmenubar.json")
        XCTAssertTrue(c.save())
        let loaded = SplashConfig.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.config.theme, .light)
        XCTAssertEqual(loaded.config.gaugeColors, ["mem": "#0000FF"])
    }

    /// A repo that isn't in the Hugging Face cache has no storage folder.
    func testStorageURLNilForUnknownRepo() {
        XCTAssertNil(SplashModels.storageURL(for: "no-such-owner/no-such-repo:UD-Q4_K_M"))
    }

    /// The "model ready" notification must fire for a download: the flag is
    /// set by the fetch announcement (or the byte bar alone) and reset for
    /// the next startup.
    func testDownloadFlagLifecycle() {
        let store = MetricsStore()
        XCTAssertFalse(store.modelDownloadedThisStartup)

        store.handle(line: "Fetching 3 file(s), 16.50 GB, from owner/repo@abc123; using xet")
        XCTAssertTrue(store.modelDownloadedThisStartup)

        store.handle(line: "14:22:03 Ready \u{B7} owner/repo \u{B7} context 256K \u{B7} http://127.0.0.1:8081")
        XCTAssertEqual(store.readyModel, "owner/repo")

        store.resetForRestart()
        XCTAssertFalse(store.modelDownloadedThisStartup)
        XCTAssertNil(store.readyModel)
    }

    /// Some starts announce the download with the byte bar alone (no
    /// "Fetching …" line); the flag must still be set.
    func testDownloadFlagSetByByteBarAlone() {
        let store = MetricsStore()
        store.handle(line: "Reconstructing (xet):  42%|####    |  6.93GB / 16.5GB,  52.1MB/s")
        XCTAssertTrue(store.modelDownloadedThisStartup)
    }

    /// The MEM bar color must not flicker: an oscillating raw pressure
    /// (warning/normal/warning …) leaves the displayed value stable, while a
    /// sustained value takes over once confirmed on two consecutive polls.
    func testMemoryPressureOscillationDoesNotFlicker() {
        let store = MetricsStore()
        func apply(pressure: String) {
            let data = "{\"memory_pressure\":\"\(pressure)\"}".data(using: .utf8)!
            store.apply(status: try! JSONDecoder().decode(StatusDoc.self, from: data))
        }
        apply(pressure: "normal")
        XCTAssertNil(store.memoryPressure)   // first sighting, not yet confirmed
        apply(pressure: "warning")
        XCTAssertNil(store.memoryPressure)   // one-poll blip, still not shown
        apply(pressure: "warning")
        XCTAssertEqual(store.memoryPressure, "warning")
        // Back to oscillating: the confirmed value holds.
        apply(pressure: "normal")
        XCTAssertEqual(store.memoryPressure, "warning")
        apply(pressure: "normal")
        XCTAssertEqual(store.memoryPressure, "normal")
    }

    /// "Reset to defaults" puts every form field back to SplashConfig.default
    /// (appearance included) and clears the flyout gauge colors on Save.
    func testResetToDefaults() {
        var c = SplashConfig.default
        c.port = 9000
        c.maxMemory = "28G"
        c.autoRestart = true
        c.launchAtLogin = true
        c.startServerOnLaunch = true
        c.theme = .dark
        c.gaugeColors = ["tok": "#123456"]
        let m = SettingsModel(config: c)
        // Before a reset, a Save carries the form's gauge colors through.
        XCTAssertEqual(m.asConfig.gaugeColors, ["tok": "#123456"])
        m.model = "custom/model:V"
        m.customModel = true
        m.port = "9999"
        m.maxMemory = "32G"
        m.autoRestart = false
        m.launchAtLogin = false
        m.refreshInterval = 10
        m.graphMinutes = 30

        m.resetToDefaults()

        let d = SplashConfig.default
        XCTAssertEqual(m.model, d.model)
        XCTAssertFalse(m.customModel)
        XCTAssertEqual(m.port, String(d.port))
        XCTAssertEqual(m.maxMemory, "")
        XCTAssertFalse(m.autoRestart)
        XCTAssertFalse(m.launchAtLogin)
        XCTAssertFalse(m.startServerOnLaunch)
        XCTAssertEqual(m.refreshInterval, d.refreshInterval)
        XCTAssertEqual(m.graphMinutes, d.graphMinutes)
        // The reset form is valid and maps to the defaults on Save.
        XCTAssertTrue(m.isValid)
        XCTAssertEqual(m.asConfig.model, d.model)
        XCTAssertEqual(m.asConfig.port, d.port)
        XCTAssertNil(m.asConfig.maxMemory)
        XCTAssertEqual(m.theme, d.theme)
        // A reset clears the gauge colors a following Save would carry.
        XCTAssertTrue(m.resetToDefaultsApplied)
        XCTAssertTrue(m.asConfig.gaugeColors.isEmpty)
    }

    /// Starting the server on launch is opt-in, and the form carries it
    /// through to Save.
    func testStartServerOnLaunchDefaultsOffAndSaves() {
        XCTAssertFalse(SplashConfig.default.startServerOnLaunch)
        let m = SettingsModel(config: .default)
        XCTAssertFalse(m.startServerOnLaunch)
        m.startServerOnLaunch = true
        XCTAssertTrue(m.asConfig.startServerOnLaunch)
        // An app-only setting: toggling it never changes the splash command.
        XCTAssertEqual(m.asConfig.serveArguments, SplashConfig.default.serveArguments)
    }

    /// Discovery and Stop only treat real splash command lines as splash.
    func testSplashCommandLineMatching() {
        XCTAssertTrue(SplashProcess.isSplashCommandLine(
            "/opt/homebrew/Cellar/splash/1.5.0/libexec/python/bin/python3 -u -P -m server.server /x --model a/b:C"))
        XCTAssertTrue(SplashProcess.isSplashCommandLine(
            "/opt/homebrew/Cellar/splash/1.5.0/libexec/engine/splash serve-native /x 98304 auto"))
        XCTAssertTrue(SplashProcess.isSplashCommandLine("splash serve --model a/b:C --port 8081"))
        XCTAssertFalse(SplashProcess.isSplashCommandLine(
            "/usr/bin/java -splash:/Applications/Data Admin.app/Contents/Resources/icon.gif -jar x.jar"))
        XCTAssertFalse(SplashProcess.isSplashCommandLine(
            "/Users/me/projects/splashmenubar/SplashMenuBar.app/Contents/MacOS/SplashMenuBar"))
        XCTAssertFalse(SplashProcess.isSplashCommandLine("python3 -m http.server 8000"))
    }
}
