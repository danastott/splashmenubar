import SwiftUI
import Combine
import AppKit

/// Editable form state for the `splash serve` parameters.
final class SettingsModel: ObservableObject {
    @Published var model: String
    @Published var port: String
    @Published var maxMemory: String
    @Published var idleRelease: String
    @Published var maxContext: String
    @Published var languageOnly: Bool
    @Published var kvFormat: String
    @Published var stateFormat: String
    @Published var disableANE: Bool
    @Published var maxCacheDisk: String
    @Published var persistentCache: Bool
    @Published var refreshInterval: Double
    @Published var graphMinutes: Int
    @Published var autoRestart: Bool
    @Published var startServerOnLaunch: Bool
    @Published var launchAtLogin: Bool
    @Published var theme: UITheme
    /// True once "Reset to defaults" was pressed, so a following Save also
    /// clears the flyout gauge colors (which the form doesn't edit itself).
    private var didResetToDefaults = false
    /// Read by the app on Save: after a reset the flyout's live gauge
    /// colors must not be carried back into the config.
    var resetToDefaultsApplied: Bool { didResetToDefaults }
    /// True when the Model field is free text instead of a listed model.
    @Published var customModel: Bool
    /// Listed models: the catalog, plus other variants found in the cache
    /// once the background scan finishes.
    @Published private(set) var modelChoices: [KnownModel] = SplashModels.catalog
    /// Bytes on disk of each fully downloaded model id.
    @Published private(set) var downloadedSizes: [String: Int64] = [:]
    /// False until the cache scan has finished.
    @Published private(set) var scanned = false
    /// Results of checking typed-in custom ids (nil value = not downloaded).
    @Published private var customSizes: [String: Int64?] = [:]
    /// The config the form was opened with, so `asConfig` can carry fields
    /// the form doesn't edit (the flyout's pin state and position) through a
    /// Save unchanged.
    let base: SplashConfig
    private var cancellables = Set<AnyCancellable>()

    static let customTag = "__custom__"

    enum DownloadStatus { case checking, downloaded(Int64), notDownloaded }

    /// Whole-GB RAM of this Mac, to check the selected model against.
    static let macMemoryGB: Int =
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    /// The model id as typed, trimmed ("" when empty).
    var modelID: String {
        model.trimmingCharacters(in: .whitespaces)
    }
    /// Parsed port, nil when the field isn't a number.
    var portValue: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }
    /// Inline validation shown under the field; nil = valid.
    var portError: String? {
        guard let v = portValue else { return "must be a number" }
        guard (1...65535).contains(v) else { return "must be between 1 and 65535" }
        return nil
    }
    var modelError: String? {
        modelID.isEmpty ? "is required" : nil
    }
    /// False while a field shows an error; Save is disabled then.
    var isValid: Bool {
        portError == nil && modelError == nil
    }

    /// The selected model from the list (nil while Custom is shown).
    var selectedModel: KnownModel? {
        modelChoices.first { $0.id == model.trimmingCharacters(in: .whitespaces) }
    }

    /// GB this Mac is short of the selected model's target RAM, if any.
    var modelMemoryShortfallGB: Int? {
        guard let m = selectedModel, let need = m.minMemoryGB,
              need > Self.macMemoryGB else { return nil }
        return need - Self.macMemoryGB
    }

    init(config: SplashConfig) {
        base = config
        model = config.model
        customModel = !SplashModels.catalog.contains { $0.id == config.model }
        port = String(config.port)
        maxMemory = config.maxMemory ?? ""
        idleRelease = config.idleRelease ?? ""
        maxContext = config.maxContext ?? ""
        languageOnly = config.languageOnly
        kvFormat = config.kvFormat ?? "int8"
        stateFormat = config.stateFormat ?? "fp32"
        disableANE = config.disableANE
        maxCacheDisk = config.maxCacheDisk ?? ""
        persistentCache = config.persistentCache
        refreshInterval = config.refreshInterval
        graphMinutes = config.graphMinutes
        autoRestart = config.autoRestart
        startServerOnLaunch = config.startServerOnLaunch
        launchAtLogin = config.launchAtLogin
        theme = config.theme

        // Scanning the Hugging Face cache walks and resolves every snapshot
        // file, so keep it off the main thread.
        let initialModel = config.model
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scan = SplashModels.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.modelChoices = SplashModels.catalog + scan.extras
                self.downloadedSizes = scan.sizes
                self.scanned = true
                // The saved model turned out to be a downloaded variant: list it.
                if self.customModel, self.model == initialModel,
                   scan.extras.contains(where: { $0.id == initialModel }) {
                    self.customModel = false
                }
            }
        }

        // Check a typed-in custom id once typing pauses, in the background.
        Publishers.CombineLatest($model, $customModel)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .map { $0.0.trimmingCharacters(in: .whitespaces) }
            .sink { [weak self] id in
                guard let self, self.customModel, !id.isEmpty,
                      self.customSizes[id] == nil else { return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let size = SplashModels.downloadedSize(id)
                    DispatchQueue.main.async { self?.customSizes[id] = .some(size) }
                }
            }
            .store(in: &cancellables)
    }

    var asConfig: SplashConfig {
        var c = SplashConfig.default
        // The UI gates Save on isValid, so the fallbacks below are only
        // reached if this is called with fields the form wouldn't accept.
        c.model = modelID.isEmpty ? SplashConfig.default.model : modelID
        c.port = portValue ?? c.port
        c.maxMemory = Self.blank(maxMemory)
        c.idleRelease = Self.blank(idleRelease)
        c.maxContext = Self.blank(maxContext)
        c.maxCacheDisk = Self.blank(maxCacheDisk)
        c.languageOnly = languageOnly
        c.kvFormat = kvFormat == "int8" ? nil : kvFormat
        c.stateFormat = stateFormat == "fp32" ? nil : stateFormat
        c.disableANE = disableANE
        c.persistentCache = persistentCache
        c.refreshInterval = refreshInterval
        c.graphMinutes = graphMinutes
        c.autoRestart = autoRestart
        c.startServerOnLaunch = startServerOnLaunch
        c.launchAtLogin = launchAtLogin
        c.theme = theme
        // The flyout's pin state and position live with the app, not the
        // form: carrying them through keeps a Save from resetting them.
        c.panelPinned = base.panelPinned
        c.pinnedPanelTopLeft = base.pinnedPanelTopLeft
        // Gauge colors live in the flyout (right-click), not the form: a
        // Save carries the current picks through — or clears them after
        // "Reset to defaults".
        c.gaugeColors = didResetToDefaults ? [:] : base.gaugeColors
        return c
    }

    /// Whether the model in the field is downloaded, from the background
    /// scan (listed models) or a debounced background check (custom ids).
    var currentStatus: DownloadStatus {
        let id = model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .notDownloaded }
        if let size = downloadedSizes[id] { return .downloaded(size) }
        if let checked = customSizes[id] {
            return checked.map { .downloaded($0) } ?? .notDownloaded
        }
        if customModel || !scanned { return .checking }
        return .notDownloaded
    }

    /// Restores every field to its default, as `SplashConfig.default`
    /// defines it (blank = splash's own default for that flag).
    func resetToDefaults() {
        let d = SplashConfig.default
        model = d.model
        customModel = !SplashModels.catalog.contains { $0.id == d.model }
        port = String(d.port)
        maxMemory = ""
        idleRelease = ""
        maxContext = ""
        maxCacheDisk = ""
        languageOnly = d.languageOnly
        kvFormat = d.kvFormat ?? "int8"
        stateFormat = d.stateFormat ?? "fp32"
        disableANE = d.disableANE
        persistentCache = d.persistentCache
        refreshInterval = d.refreshInterval
        graphMinutes = d.graphMinutes
        autoRestart = d.autoRestart
        startServerOnLaunch = d.startServerOnLaunch
        launchAtLogin = d.launchAtLogin
        theme = d.theme
        didResetToDefaults = true
    }

    private static func blank(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// Form for the `splash serve` command-line parameters.
struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    let onSave: (SplashConfig) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("splash serve — parameters")
                .font(.system(size: 13, weight: .semibold))
            VStack(spacing: 8) {
                field("Model", help: "--model: a supported model, or Custom… for any Hugging Face model as OWNER/REPO[:VARIANT] with the GGUF variant after ':'. Downloaded models are found in the Hugging Face cache; others download on first start, along with their draft.") {
                    modelPicker
                }
                field("Port", help: "--port: HTTP port the server listens on (127.0.0.1).") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("8081", text: $settings.port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        if let err = settings.portError {
                            Text("Port \(err)")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                }
                field("Max memory", help: "--max-memory: Metal memory budget, e.g. 28G. It can only lower the automatic budget. Blank = auto.") {
                    TextField("auto (e.g. 28G)", text: $settings.maxMemory)
                        .textFieldStyle(.roundedBorder)
                }
                field("Idle release", help: "--idle-release: time without a request before splash frees the model weights and memory, e.g. 30m, 1h; off keeps them loaded. Blank = 10m.") {
                    TextField("10m default (e.g. off)", text: $settings.idleRelease)
                        .textFieldStyle(.roundedBorder)
                }
                field("Max context", help: "--max-context: context token limit, e.g. 100K or 1M. Past the model's native window (256K) it turns on YaRN, which changes answers, so go higher only when needed. Blank = auto.") {
                    TextField("auto (e.g. 100K)", text: $settings.maxContext)
                        .textFieldStyle(.roundedBorder)
                }
                field("KV format", help: "--kv-format: storage for the KV cache. int8 (default) uses less memory; bf16 uses more.") {
                    Picker("", selection: $settings.kvFormat) {
                        Text("int8 (default)").tag("int8")
                        Text("bf16").tag("bf16")
                    }
                    .frame(width: 160)
                }
                field("State format", help: "--state-format: storage for recurrent state. fp32 (default); bf16 halves each state, so memory and the SSD cache hold about twice as many.") {
                    Picker("", selection: $settings.stateFormat) {
                        Text("fp32 (default)").tag("fp32")
                        Text("bf16").tag("bf16")
                    }
                    .frame(width: 160)
                }
                field("Max cache disk", help: "--max-cache-disk: SSD quota for cached KV pages and states, e.g. 16G; 0 disables the SSD cache. Blank = auto (a quarter of free space, at most 32G).") {
                    TextField("auto (e.g. 16G; 0 = off)", text: $settings.maxCacheDisk)
                        .textFieldStyle(.roundedBorder)
                }
                field("Language only", help: "--language-only: skip loading vision; image and PDF input is refused. Saves memory and startup time.") {
                    Toggle("", isOn: $settings.languageOnly)
                        .frame(width: 160)
                }
                field("Disable Neural Engine", help: "--disable-ane: prefill on the GPU alone. By default long prompts on dense models also use the Neural Engine when that's faster.") {
                    Toggle("", isOn: $settings.disableANE)
                        .frame(width: 160)
                }
                field("Persistent cache", help: "--persistent-cache: keep the SSD prompt cache across restarts, so earlier conversations resume without re-prefilling.") {
                    Toggle("", isOn: $settings.persistentCache)
                        .frame(width: 160)
                }
            }
            Divider()
            field("UI refresh", help: "How often the app polls splash's /status endpoint to update the flyout and the menu bar. Faster is more responsive and costs a little more CPU. Changing only this does not restart the server.") {
                Picker("", selection: $settings.refreshInterval) {
                    ForEach(SplashConfig.refreshIntervalChoices, id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms" : "\(Int(v)) s" + (v == 2 ? " (default)" : "")).tag(v)
                    }
                }
                .frame(width: 160)
            }
            field("Speed graph span", help: "How many minutes of generation the tok/s graph shows. Only time spent generating is sampled, so idle gaps don't count. Changing only this does not restart the server.") {
                Picker("", selection: $settings.graphMinutes) {
                    ForEach(SplashConfig.graphMinutesChoices, id: \.self) { m in
                        Text("\(m) min" + (m == 5 ? " (default)" : "")).tag(m)
                    }
                }
                .frame(width: 160)
            }
            field("Auto-restart", help: "If splash exits on its own, start it again after a moment — up to \(SplashProcess.maxAutoRestarts) times in a row before giving up. Pressing Start resets the count; a Stop always wins over it. A crash also gets a notification unless it is being auto-restarted.") {
                Toggle("", isOn: $settings.autoRestart)
                    .frame(width: 160)
            }
            field("Start 'splash' server on launch", help: "Start the splash server with the model above whenever Splash Menu Bar launches. Off by default: the app opens with the server stopped (a splash already running on the port is still picked up), and you press Start. Changing it does not restart the server.") {
                Toggle("", isOn: $settings.startServerOnLaunch)
                    .frame(width: 160)
            }
            field("Launch at login", help: "Start Splash Menu Bar when you log in — with Start 'splash' server on launch also on, the splash server comes up without opening the app. Registered as a system login item (System Settings → General → Login Items); changing it does not restart the server.") {
                Toggle("", isOn: $settings.launchAtLogin)
                    .frame(width: 160)
            }
            field("Appearance", help: "The flyout's (and this window's) color theme: follow the system's dark/light mode, or force one. The preview here updates as you pick; the flyout takes it on Save. Changing only this does not restart the server.") {
                Picker("", selection: $settings.theme) {
                    ForEach(UITheme.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .frame(width: 160)
            }
            Text("Changing a splash option restarts the server.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Reset to defaults", action: { settings.resetToDefaults() })
                    .help("Set every option to its default. Nothing is saved or restarted until you press Save.")
                Spacer()
                Button("Cancel", action: onDismiss)
                    .help("Close without saving.")
                Button("Save", action: { onSave(settings.asConfig) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!settings.isValid)
                    .help("Save these options to ~/.splashmenubar.json and restart splash with them.")
            }
        }
        .padding(16)
        .frame(width: 440)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - Model picker

    private var modelSelection: Binding<String> {
        Binding(
            get: { settings.customModel ? SettingsModel.customTag : settings.model },
            set: { v in
                if v == SettingsModel.customTag {
                    settings.customModel = true
                } else {
                    settings.customModel = false
                    settings.model = v
                }
            })
    }

    private var modelPicker: some View {
        let downloaded = settings.modelChoices.filter { settings.downloadedSizes[$0.id] != nil }
        let available = settings.modelChoices.filter { settings.downloadedSizes[$0.id] == nil }
        return VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: modelSelection) {
                if !downloaded.isEmpty {
                    Section("Downloaded") {
                        ForEach(downloaded) { m in
                            Text("\(m.label) — \(Fmt.bytes(Int(settings.downloadedSizes[m.id] ?? 0)))").tag(m.id)
                        }
                    }
                }
                if !available.isEmpty {
                    Section("Not downloaded") {
                        ForEach(available) { m in
                            Text(m.label + (m.downloadGB.map { " · \($0) GB download" } ?? ""))
                                .tag(m.id)
                        }
                    }
                }
                Divider()
                Text("Custom…").tag(SettingsModel.customTag)
            }
            .labelsHidden()
            if settings.customModel {
                TextField("OWNER/REPO[:VARIANT]", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                if let err = settings.modelError {
                    Text("Model \(err)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            modelStatus
            if let need = settings.selectedModel?.minMemoryGB,
               let shortfall = settings.modelMemoryShortfallGB {
                Label("Needs about \(need) GB of RAM — this Mac has \(SettingsModel.macMemoryGB) GB, so this model will likely not run here",
                      systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.system(size: 10))
            }
            if !settings.customModel, let about = settings.selectedModel?.about {
                Text(about)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch settings.currentStatus {
        case .downloaded(let size):
            let text = "Downloaded · \(Fmt.bytes(Int(size))) on disk"
            if let url = SplashModels.storageURL(for: settings.modelID) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(text)
                            .foregroundColor(.blue)
                            .underline()
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Open in Finder the folder where this model is stored (the Hugging Face cache).")
            } else {
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 10))
            }
        case .notDownloaded:
            Label("Not downloaded · the first start downloads it", systemImage: "arrow.down.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 10))
        case .checking:
            Label("Checking the model cache…", systemImage: "hourglass")
                .foregroundColor(.secondary)
                .font(.system(size: 10))
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help)
    }
}
