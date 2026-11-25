import SwiftUI
import Combine
import AppKit

/// The app's version from Info.plist: the short version with the build
/// number in parentheses when it differs ("1.0 (2)"); "?" when the bare
/// binary runs outside the .app bundle. (Defined here, not in App.swift,
/// so the test build — which excludes App.swift — still sees it.)
let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    guard let build = info?["CFBundleVersion"] as? String, build != short else {
        return short
    }
    return "\(short) (\(build))"
}()

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
    @Published var maxConcurrentRequests: Int?
    @Published var samplingDefaults: String
    @Published var activations: String
    @Published var verifyRows: String
    @Published var cachedStates: String
    @Published var recalibrateANE: Bool
    @Published var pinModelVersion: Bool
    @Published var refreshInterval: Double
    @Published var graphMinutes: Int
    @Published var autoRestart: Bool
    @Published var startServerOnLaunch: Bool
    @Published var launchAtLogin: Bool
    /// The Notifications tab: one toggle per banner the app can post.
    @Published var notifyRequestFinished: Bool
    @Published var notifyRequestStuck: Bool
    @Published var notifyModelReady: Bool
    @Published var notifyThermal: Bool
    @Published var notifyWeightsReleased: Bool
    @Published var notifyCrash: Bool
    @Published var theme: UITheme
    @Published var temperatureUnit: TemperatureUnit
    /// UI language choice ("" = system); persisted to app defaults, not to
    /// the server config.
    @Published var language: String
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
    /// The sampling field names splash's --sampling-default accepts.
    static let samplingFields = ["temperature", "top_p", "top_k", "min_p",
                                 "presence_penalty", "frequency_penalty",
                                 "repetition_penalty"]
    /// Inline validation for the Sampling defaults field; nil = valid.
    var samplingDefaultsError: String? {
        for pair in samplingDefaults.split(whereSeparator: \.isWhitespace) {
            let kv = pair.split(separator: "=", maxSplits: 1,
                                omittingEmptySubsequences: false)
            guard kv.count == 2,
                  Self.samplingFields.contains(String(kv[0])),
                  Double(kv[1]) != nil else {
                return "must be NAME=VALUE pairs, NAME one of: "
                    + Self.samplingFields.joined(separator: ", ")
            }
        }
        return nil
    }
    /// False while a field shows an error; Save is disabled then.
    var isValid: Bool {
        portError == nil && modelError == nil && samplingDefaultsError == nil
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
        maxConcurrentRequests = config.maxConcurrentRequests
        samplingDefaults = config.samplingDefaults ?? ""
        activations = config.activations ?? "auto"
        verifyRows = config.verifyRows ?? "auto"
        cachedStates = config.cachedStates ?? "int8"
        recalibrateANE = config.recalibrateANE
        pinModelVersion = config.pinModelVersion
        refreshInterval = config.refreshInterval
        graphMinutes = config.graphMinutes
        autoRestart = config.autoRestart
        startServerOnLaunch = config.startServerOnLaunch
        launchAtLogin = config.launchAtLogin
        notifyRequestFinished = config.notificationsEnabled(.requestFinished)
        notifyRequestStuck = config.notificationsEnabled(.requestStuck)
        notifyModelReady = config.notificationsEnabled(.modelReady)
        notifyThermal = config.notificationsEnabled(.thermal)
        notifyWeightsReleased = config.notificationsEnabled(.weightsReleased)
        notifyCrash = config.notificationsEnabled(.crash)
        theme = config.theme
        temperatureUnit = config.temperatureUnit
        language = AppLanguage.selected()

        // Scanning the Hugging Face cache walks and resolves every snapshot
        // file, so keep it off the main thread.
        rescan()

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
        c.maxConcurrentRequests = maxConcurrentRequests
        c.samplingDefaults = Self.blank(samplingDefaults)
        c.activations = activations == "auto" ? nil : activations
        c.verifyRows = verifyRows == "auto" ? nil : verifyRows
        c.cachedStates = cachedStates == "int8" ? nil : cachedStates
        c.recalibrateANE = recalibrateANE
        c.pinModelVersion = pinModelVersion
        c.refreshInterval = refreshInterval
        c.graphMinutes = graphMinutes
        c.autoRestart = autoRestart
        c.startServerOnLaunch = startServerOnLaunch
        c.launchAtLogin = launchAtLogin
        c.notifications = [
            NotificationKind.requestFinished.rawValue: notifyRequestFinished,
            NotificationKind.requestStuck.rawValue: notifyRequestStuck,
            NotificationKind.modelReady.rawValue: notifyModelReady,
            NotificationKind.thermal.rawValue: notifyThermal,
            NotificationKind.weightsReleased.rawValue: notifyWeightsReleased,
            NotificationKind.crash.rawValue: notifyCrash,
        ]
        c.theme = theme
        c.temperatureUnit = temperatureUnit
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

    /// Runs the background cache scan; call it again after the cache
    /// changed (e.g. Manage models) so the picker's downloaded list
    /// refreshes.
    func rescan() {
        let initialModel = base.model
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
        maxConcurrentRequests = d.maxConcurrentRequests
        samplingDefaults = d.samplingDefaults ?? ""
        activations = d.activations ?? "auto"
        verifyRows = d.verifyRows ?? "auto"
        cachedStates = d.cachedStates ?? "int8"
        recalibrateANE = d.recalibrateANE
        pinModelVersion = d.pinModelVersion
        refreshInterval = d.refreshInterval
        graphMinutes = d.graphMinutes
        autoRestart = d.autoRestart
        startServerOnLaunch = d.startServerOnLaunch
        launchAtLogin = d.launchAtLogin
        notifyRequestFinished = d.notificationsEnabled(.requestFinished)
        notifyRequestStuck = d.notificationsEnabled(.requestStuck)
        notifyModelReady = d.notificationsEnabled(.modelReady)
        notifyThermal = d.notificationsEnabled(.thermal)
        notifyWeightsReleased = d.notificationsEnabled(.weightsReleased)
        notifyCrash = d.notificationsEnabled(.crash)
        theme = d.theme
        language = ""
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
    @ObservedObject var harnesses: HarnessModel
    let onSave: (SplashConfig) -> Void
    let onDismiss: () -> Void
    let onManageModels: () -> Void

    /// Help text shared by the Model row and the Custom field row.
    private static var modelHelp: String {
        String(localized: "--model: a supported model, or Custom… for any Hugging Face model as OWNER/REPO[:VARIANT] with the GGUF variant after ':'. Downloaded models are found in the Hugging Face cache; others download on first start, along with their draft.")
    }

    /// The config file's path, with the home directory shown as ~.
    private var configFileDisplay: String {
        SplashConfig.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                modelPane
                    .tabItem { Label("Model", systemImage: "cpu") }
                harnessPane
                    .tabItem { Label("AI harness", systemImage: "terminal") }
                serverPane
                    .tabItem { Label("Server", systemImage: "server.rack") }
                notificationsPane
                    .tabItem { Label("Notifications", systemImage: "bell") }
                appPane
                    .tabItem { Label("App", systemImage: "gearshape") }
                aboutPane
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            // One SettingsModel backs every tab, so this bar always acts
            // on the whole draft, whatever tab is open.
            HStack {
                Button("Reset to defaults", action: { settings.resetToDefaults() })
                    .help("Set every option to its default. Nothing is saved or restarted until you press Save.")
                Spacer()
                Button("Cancel", action: onDismiss)
                    .help("Close without saving.")
                Button("Save", action: {
                    let languageChanged = AppLanguage.selected() != settings.language
                    AppLanguage.persist(settings.language)
                    onSave(settings.asConfig)
                    if languageChanged {
                        // The choice is persisted, but macOS reads the app's
                        // language at launch, so offer the relaunch.
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Relaunch to apply the language?")
                        alert.informativeText = String(localized: "The new language takes effect when Splash Menu Bar relaunches. The splash server keeps running.")
                        alert.addButton(withTitle: String(localized: "Relaunch Now"))
                        alert.addButton(withTitle: String(localized: "Later"))
                        if alert.runModal() == .alertFirstButtonReturn {
                            AppDelegate.shared?.relaunch()
                        }
                    }
                })
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!settings.isValid)
                .help("Save these options to ~/.splashmenubar.json and restart splash with them.")
            }
            .padding(12)
        }
        .frame(width: 560)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - Panes

    private var modelPane: some View {
        Form {
            Section {
                if settings.customModel {
                    LabeledContent("Model") {
                        TextField("OWNER/REPO[:VARIANT]", text: $settings.model)
                            .textFieldStyle(.roundedBorder)
                    }
                    .help(Self.modelHelp)
                    if let err = settings.modelError {
                        Text("Model \(err)")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                } else {
                    modelPicker
                        .help(Self.modelHelp)
                }
                VStack(alignment: .leading, spacing: 4) {
                    modelStatus
                    if let need = settings.selectedModel?.minMemoryGB,
                       settings.modelMemoryShortfallGB != nil {
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
                LabeledContent("Model cache") {
                    Button("Manage…") { onManageModels() }
                }
                .help("The Hugging Face cache (~/.cache/huggingface/hub) where splash keeps downloaded models, including the separate versions of a repo it has fetched. Manage lists them, downloads new models, and removes what's no longer wanted.")
                Toggle("Pin model version", isOn: $settings.pinModelVersion)
                    .help("--revision: pin splash to the commit of the model already in the Hugging Face cache, so a new commit on the repository's default branch is not re-downloaded over the copy on disk. Off by default, when splash follows the default branch. With no complete copy in the cache there is no version to pin, so the first start downloads as usual and only restarts after are pinned.")
            }
        }
        .formStyle(.grouped)
    }

    private var harnessPane: some View {
        Form {
            Section {
                Picker("AI harness", selection: $harnesses.selectedID) {
                    ForEach(harnesses.supported) { h in
                        if harnesses.installedIDs.contains(h.id) {
                            Text(h.name).tag(Optional(h.id))
                        } else {
                            // The ternary form coerced both branches to String
                            // and skipped localization of "(not installed)".
                            Text("\(h.name) (not installed)").tag(Optional(h.id))
                        }
                    }
                }
                .labelsHidden()
                .help("Point a coding harness at the splash server. Auto Connect writes the harness's own configuration, so it uses splash from a terminal too; start it in a new session after connecting. Every supported harness is listed; the uninstalled ones can be connected once their binary is on the PATH.")
                .onChange(of: harnesses.selectedID) { _ in
                    harnesses.selectionChanged()
                }
                VStack(alignment: .leading, spacing: 4) {
                    harnessStatusLine
                    HStack(spacing: 8) {
                        let title: LocalizedStringKey = harnesses.busy ? "Connecting…" : "Auto Connect"
                        Button(title) {
                            harnesses.connect()
                        }
                        .disabled(harnesses.busy || !harnesses.selectedIsInstalled)
                        if !harnesses.selectedIsInstalled {
                            Text("Install it to connect it — Auto Connect writes the harness's own configuration.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else if let note = harnesses.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var serverPane: some View {
        Form {
            Section {
                LabeledContent("Port") {
                    // An explicit prompt, not a title: a title hoists out of
                    // the LabeledContent as a second gray "8000" beside the
                    // field (read as the remembered value).
                    TextField("", text: $settings.port, prompt: Text("8000"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                .help("--port: HTTP port the server listens on (127.0.0.1).")
                if let err = settings.portError {
                    Text("Port \(err)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                TextField("Max memory", text: $settings.maxMemory, prompt: Text("auto (e.g. 28G)"))
                    .help("--max-memory: Metal memory budget, e.g. 28G. It can only lower the automatic budget. Blank = auto.")
                TextField("Idle release", text: $settings.idleRelease, prompt: Text("10m default (e.g. off)"))
                    .help("--idle-release: time without a request before splash frees the model weights and memory, e.g. 30m, 1h; off keeps them loaded. Blank = 10m.")
                TextField("Max context", text: $settings.maxContext, prompt: Text("auto (e.g. 100K)"))
                    .help("--max-context: context token limit, e.g. 100K or 1M. Past the model's native window (256K) it turns on YaRN, which changes answers, so go higher only when needed. Blank = auto.")
                Picker("KV format", selection: $settings.kvFormat) {
                    Text("int8 (default)").tag("int8")
                    Text("bf16").tag("bf16")
                }
                .help("--kv-format: storage for the KV cache. int8 (default) uses less memory; bf16 uses more.")
                Picker("State format", selection: $settings.stateFormat) {
                    Text("fp32 (default)").tag("fp32")
                    Text("bf16").tag("bf16")
                }
                .help("--state-format: storage for recurrent state. fp32 (default); bf16 halves each state, so memory and the SSD cache hold about twice as many.")
                TextField("Max cache disk", text: $settings.maxCacheDisk, prompt: Text("auto (e.g. 16G; 0 = off)"))
                    .help("--max-cache-disk: SSD quota for cached KV pages and states, e.g. 16G; 0 disables the SSD cache. Blank = auto (a quarter of free space, at most 32G).")
                Toggle("Language only", isOn: $settings.languageOnly)
                    .help("--language-only: skip loading vision; image and PDF input is refused. Saves memory and startup time.")
                Toggle("Disable Neural Engine", isOn: $settings.disableANE)
                    .help("--disable-ane: prefill on the GPU alone. By default long prompts on dense models also use the Neural Engine when that's faster.")
                Toggle("Persistent cache", isOn: $settings.persistentCache)
                    .help("--persistent-cache: keep the SSD prompt cache across restarts, so earlier conversations resume without re-prefilling.")
                Picker("Concurrency limit", selection: $settings.maxConcurrentRequests) {
                    ForEach(1...8, id: \.self) { n in
                        if n == 4 {
                            Text("4 (default)").tag(Int?.none)
                        } else {
                            Text("\(n)").tag(Int?.some(n))
                        }
                    }
                }
                .help("--max-concurrent-requests: requests the engine runs at once, 1 to 8 (default 4). More let more clients be answered together, each a little slower, and take memory for their states and arenas — where that streams more of the weights or leaves less context than four would, the start logs both.")
            } header: {
                Text("splash serve — parameters")
            } footer: {
                Text("Changing a splash option restarts the server.")
            }
            Section {
                TextField("Sampling defaults", text: $settings.samplingDefaults,
                          prompt: Text("e.g. temperature=0.7 top_p=0.9"))
                    .help("--sampling-default: the value of a sampling parameter for requests that set none — NAME=VALUE pairs, space separated, one of: temperature, top_p, top_k, min_p, presence_penalty, frequency_penalty, repetition_penalty. Blank = the served model's published sampling.")
                if let err = settings.samplingDefaultsError {
                    Text("Sampling defaults \(err)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                Picker("Activations", selection: $settings.activations) {
                    Text("auto (default)").tag("auto")
                    Text("bf16").tag("bf16")
                }
                .help("--activations: auto (default) rounds activations to 8 bits where the GPU multiplies them twice as fast (M5 and later) — faster, but outputs can differ at near ties; bf16 keeps every activation exact, for evaluations and parity.")
                Picker("Verify rows", selection: $settings.verifyRows) {
                    Text("auto (default)").tag("auto")
                    Text("all").tag("all")
                }
                .help("--verify-rows: auto (default) picks each decode cycle's verified rows by the costs the start measured — faster, but greedy and seeded outputs can differ from run to run; all verifies every row, so those outputs repeat.")
                Picker("Cached states", selection: $settings.cachedStates) {
                    Text("int8 (default)").tag("int8")
                    Text("exact").tag("exact")
                }
                .help("--cached-states: storage of cached recurrent states. int8 (default) codes take about a quarter of an fp32 state, and a restored state can differ at near ties; exact keeps the State format's precision, so a restore is exact.")
                Toggle("Recalibrate Neural Engine", isOn: $settings.recalibrateANE)
                    .disabled(settings.disableANE)
                    .help("--recalibrate-ane: calibrate the Neural Engine's share of long prompts again at every start instead of taking the one this Mac kept. Useful after another app used the Neural Engine heavily — a calibration taken beside a busy Mac keeps a smaller share. Unavailable while the Neural Engine is disabled.")
            } header: {
                Text("splash serve — advanced")
            } footer: {
                Text("Changing a splash option restarts the server.")
            }
        }
        .formStyle(.grouped)
    }

    private var notificationsPane: some View {
        Form {
            Section {
                Toggle("Request finished", isOn: $settings.notifyRequestFinished)
                    .help("Post a notification when a request that ran at least \(Int(RequestMetrics.notifyMinSeconds)) seconds finishes, with its output tokens and speed. Shorter requests stay silent. App-launched servers only — a server started outside the app has no log for the app to read. Clicking the banner reopens the flyout. Changing it does not restart the server.")
                Toggle("Request appears stuck", isOn: $settings.notifyRequestStuck)
                    .help("Post a notification when a request makes no progress for a minute; the flyout also shows an orange stuck card. Changing it does not restart the server.")
                Toggle("Model ready", isOn: $settings.notifyModelReady)
                    .help("Post a notification when a downloaded model has loaded and is serving; loading a model that is already on disk stays silent. Changing it does not restart the server.")
                Toggle("Thermal warnings", isOn: $settings.notifyThermal)
                    .help("Post a notification when the Mac's thermal state crosses into serious or critical, when the CPU and GPU are being throttled and generation slows down. Changing it does not restart the server.")
                Toggle("splash released the model", isOn: $settings.notifyWeightsReleased)
                    .help("Post a notification when, after idleness, splash frees the model weights from memory to give the RAM back; the next request restores them and is slower. Changing it does not restart the server.")
                Toggle("splash exited", isOn: $settings.notifyCrash)
                    .help("Post a notification with a Start splash action when splash exits on its own. A crash that is being auto-restarted stays silent either way. Changing it does not restart the server.")
            }
        }
        .formStyle(.grouped)
    }

    private var appPane: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.language) {
                    Text("System (\(AppLanguage.systemLanguageName))").tag("")
                    ForEach(AppLanguage.supported, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .help("The app's UI language. System (the default) follows the computer's language — System Settings → General → Language & Region — and falls back to English when the system language isn't supported. Saving a different language relaunches the app to apply it; the splash server keeps running.")
                Picker("UI refresh", selection: $settings.refreshInterval) {
                    ForEach(SplashConfig.refreshIntervalChoices, id: \.self) { v in
                        Text(v < 1 ? "\(Int(v * 1000)) ms"
                                  : v == 2 ? "\(Int(v)) s (default)"
                                          : "\(Int(v)) s").tag(v)
                    }
                }
                .help("How often the app polls splash's /status endpoint to update the flyout and the menu bar. Faster is more responsive and costs a little more CPU. Changing only this does not restart the server.")
                Picker("Speed graph span", selection: $settings.graphMinutes) {
                    ForEach(SplashConfig.graphMinutesChoices, id: \.self) { m in
                        Text(m == 5 ? "\(m) min (default)" : "\(m) min").tag(m)
                    }
                }
                .help("How many minutes of generation the tok/s graph shows. Only time spent generating is sampled, so idle gaps don't count. Changing only this does not restart the server.")
                Toggle("Auto-restart", isOn: $settings.autoRestart)
                    .help("If splash exits on its own, start it again after a moment — up to \(SplashProcess.maxAutoRestarts) times in a row before giving up. Pressing Start resets the count; a Stop always wins over it. A crash also gets a notification unless it is being auto-restarted.")
                Toggle("Start 'splash' server on launch", isOn: $settings.startServerOnLaunch)
                    .help("Start the splash server with the model above whenever Splash Menu Bar launches. Off by default: the app opens with the server stopped (a splash already running on the port is still picked up), and you press Start. Changing it does not restart the server.")
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .help("Start Splash Menu Bar when you log in — with Start 'splash' server on launch also on, the splash server comes up without opening the app. Registered as a system login item (System Settings → General → Login Items); changing it does not restart the server.")
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(UITheme.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .help("The flyout's (and this window's) color theme: follow the system's dark/light mode, or force one. The preview here updates as you pick; the flyout takes it on Save. Changing only this does not restart the server.")
                Picker("Temperature", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { u in
                        Text(u.label).tag(u)
                    }
                }
                .help("The unit the chip temperature shows in. System (the default) follows the computer's region — System Settings → General → Language & Region; pick Fahrenheit or Celsius to override it. Changing only this does not restart the server.")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            Section {
                Text("Splash Menu Bar")
                    .font(.system(size: 14, weight: .semibold))
                LabeledContent("Version") {
                    Text(appVersion)
                        .textSelection(.enabled)
                        .help("The version of this app (from its bundle).")
                }
                LabeledContent("Config file") {
                    Text(configFileDisplay)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
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
        return Picker("Model", selection: modelSelection) {
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
                        if let gb = m.downloadGB {
                            Text("\(m.label) · \(gb) GB").tag(m.id)
                        } else {
                            Text(m.label).tag(m.id)
                        }
                    }
                }
            }
            Divider()
            Text("Custom…").tag(SettingsModel.customTag)
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch settings.currentStatus {
        case .downloaded(let size):
            let text = String(localized: "Downloaded · \(Fmt.bytes(Int(size))) on disk")
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
    private var harnessStatusLine: some View {
        switch harnesses.status {
        case .connected:
            Label("Connected to this splash server", systemImage: "checkmark.circle")
                .foregroundColor(.green)
                .font(.system(size: 11))
        case .elsewhere(let url):
            Label("Points at \(url)", systemImage: "arrow.turn.down.right")
                .foregroundColor(.orange)
                .font(.system(size: 11))
                .textSelection(.enabled)
        case .notInstalled:
            Label("Not installed", systemImage: "circle.dashed")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
        case .notConfigured:
            Label("Not configured", systemImage: "circle.dashed")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
        case .unreadable(let reason):
            Label("Config unreadable: \(reason)", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.system(size: 11))
        }
    }
}

/// Root of the standard Settings scene. The form state is owned by the
/// app delegate (its `settingsModel` / `harnesses` accessors) so it
/// survives the window closing and other code can reach it; this view
/// just binds to it and routes actions back to the delegate.
struct SettingsSceneView: View {
    @ObservedObject private var settings: SettingsModel
    @ObservedObject private var harnesses: HarnessModel

    init() {
        let delegate = AppDelegate.shared
        let settings = delegate?.settingsModel ?? SettingsModel(config: SplashConfig.load().config)
        let harnesses = delegate?.harnesses ?? HarnessModel(connectionProvider: { nil })
        _settings = ObservedObject(wrappedValue: settings)
        _harnesses = ObservedObject(wrappedValue: harnesses)
    }

    var body: some View {
        SettingsView(
            settings: settings,
            harnesses: harnesses,
            onSave: { saved in
                AppDelegate.shared?.applySettings(saved)
            },
            onDismiss: {
                AppDelegate.shared?.dismissSettings()
            },
            onManageModels: {
                AppDelegate.shared?.openManageModels()
            }
        )
        .onAppear {
            // A harness (or a model) may have been installed or downloaded
            // since the window was last open; refresh both lists.
            harnesses.rescan()
            settings.rescan()
        }
    }
}
