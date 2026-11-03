import SwiftUI

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
    /// True when the Model field is free text instead of a listed model.
    @Published var customModel: Bool
    /// Listed models: the catalog plus other variants found in the cache.
    let modelChoices: [KnownModel]
    /// Bytes on disk of each fully downloaded model id.
    let downloadedSizes: [String: Int64]

    static let customTag = "__custom__"

    init(config: SplashConfig) {
        model = config.model
        let scan = SplashModels.scan()
        modelChoices = SplashModels.catalog + scan.extras
        downloadedSizes = scan.sizes
        customModel = !modelChoices.contains { $0.id == config.model }
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
    }

    var asConfig: SplashConfig {
        var c = SplashConfig.default
        let m = model.trimmingCharacters(in: .whitespaces)
        c.model = m.isEmpty ? SplashConfig.default.model : m
        c.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? SplashConfig.default.port
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
        return c
    }

    /// Bytes on disk for the model in the field (custom ids are checked live).
    var currentDownloadedSize: Int64? {
        let id = model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return downloadedSizes[id] ?? (customModel ? SplashModels.downloadedSize(id) : nil)
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
                    TextField("8081", text: $settings.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
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
            HStack {
                Text("Changing a splash option restarts the server.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: onDismiss)
                    .help("Close without saving.")
                Button("Save", action: { onSave(settings.asConfig) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Save these options to ~/.splashmenubar.json and restart splash with them.")
            }
        }
        .padding(16)
        .frame(width: 440)
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
                        ForEach(available) { m in Text(m.label).tag(m.id) }
                    }
                }
                Divider()
                Text("Custom…").tag(SettingsModel.customTag)
            }
            .labelsHidden()
            if settings.customModel {
                TextField("OWNER/REPO[:VARIANT]", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
            }
            modelStatus
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let size = settings.currentDownloadedSize {
            Label("Downloaded · \(Fmt.bytes(Int(size))) on disk", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 10))
        } else {
            Label("Not downloaded · the first start downloads it", systemImage: "arrow.down.circle")
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
