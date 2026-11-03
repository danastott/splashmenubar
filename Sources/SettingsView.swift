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

    init(config: SplashConfig) {
        model = config.model
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
        return c
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
                field("Model") {
                    TextField("OWNER/REPO[:VARIANT]", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                }
                field("Port") {
                    TextField("8081", text: $settings.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                field("Max memory") {
                    TextField("auto (e.g. 28G)", text: $settings.maxMemory)
                        .textFieldStyle(.roundedBorder)
                }
                field("Idle release") {
                    TextField("10m default (e.g. off)", text: $settings.idleRelease)
                        .textFieldStyle(.roundedBorder)
                }
                field("Max context") {
                    TextField("auto (e.g. 100K)", text: $settings.maxContext)
                        .textFieldStyle(.roundedBorder)
                }
                field("KV format") {
                    Picker("", selection: $settings.kvFormat) {
                        Text("int8 (default)").tag("int8")
                        Text("bf16").tag("bf16")
                    }
                    .frame(width: 160)
                }
                field("State format") {
                    Picker("", selection: $settings.stateFormat) {
                        Text("fp32 (default)").tag("fp32")
                        Text("bf16").tag("bf16")
                    }
                    .frame(width: 160)
                }
                field("Max cache disk") {
                    TextField("auto (e.g. 16G; 0 = off)", text: $settings.maxCacheDisk)
                        .textFieldStyle(.roundedBorder)
                }
                field("Language only") {
                    Toggle("", isOn: $settings.languageOnly)
                        .frame(width: 160)
                }
                field("Disable Neural Engine") {
                    Toggle("", isOn: $settings.disableANE)
                        .frame(width: 160)
                }
                field("Persistent cache") {
                    Toggle("", isOn: $settings.persistentCache)
                        .frame(width: 160)
                }
            }
            HStack {
                Text("Saving restarts the server.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: onDismiss)
                Button("Save", action: { onSave(settings.asConfig) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            content()
        }
    }
}
