import Foundation
import SwiftUI

/// A coding harness that can be pointed at the local splash server.
struct AIHarness: Identifiable, Hashable {
    let id: String
    let name: String
    let binary: String
}

enum AIHarnesses {
    /// Every supported harness, display order.
    static let all: [AIHarness] = [
        .init(id: "claude", name: "Claude Code", binary: "claude"),
        .init(id: "codex", name: "Codex", binary: "codex"),
        .init(id: "pi", name: "pi", binary: "pi"),
        .init(id: "omp", name: "omp", binary: "omp"),
        .init(id: "hermes", name: "Hermes", binary: "hermes"),
        .init(id: "opencode", name: "OpenCode", binary: "opencode"),
        .init(id: "copilot", name: "Copilot CLI", binary: "copilot"),
        .init(id: "droid", name: "Droid", binary: "droid"),
        .init(id: "grok", name: "Grok Build", binary: "grok"),
        .init(id: "kilo", name: "Kilo", binary: "kilo"),
        .init(id: "kimi", name: "Kimi Code", binary: "kimi"),
        .init(id: "mastracode", name: "Mastra Code", binary: "mastracode"),
        .init(id: "qwen", name: "Qwen Code", binary: "qwen"),
    ]

    /// The installed ones (binary found on the app's child PATH), in `all`
    /// order.
    static func installed() -> [AIHarness] {
        all.filter { SplashInstaller.locate($0.binary) != nil }
    }
}

/// Where a harness's configuration currently points.
enum HarnessStatus: Equatable {
    case notInstalled
    case notConfigured
    case connected
    /// Points at another URL (the URL, as the config spells it).
    case elsewhere(String)
    /// The config file is present but unparseable; the reason, short.
    case unreadable(String)
}

/// What an Auto Connect writes: the app's configured splash server.
struct HarnessConnection: Equatable {
    let port: Int
    /// Served model name, non-empty.
    let model: String
    /// Context tokens, > 0.
    let context: Int
    /// Input modalities; contains "text".
    let modalities: [String]

    var baseUrl: String { "http://127.0.0.1:\(port)" }
    var endpoint: String { baseUrl + "/v1" }
    /// The name splash's own launcher gives the server: "splash" on the
    /// default port, "splash-<port>" on another, so one client can hold a
    /// provider per server.
    var providerName: String { port == 8000 ? "splash" : "splash-\(port)" }
}

/// Reads and writes the persistent configuration of one installed harness,
/// mirroring what splash 1.6.x's own client launchers write — persistently.
enum HarnessConnector {

    static func status(_ h: AIHarness, connection: HarnessConnection,
                       home: URL? = nil) -> HarnessStatus {
        switch h.id {
        case "claude": return claudeStatus(connection, home: home)
        case "codex": return codexStatus(connection, home: home)
        case "pi": return piStatus(connection, home: home)
        case "omp": return ompStatus(connection, home: home)
        case "hermes": return hermesStatus(connection, home: home)
        case "opencode": return opencodeStatus(connection, home: home)
        case "copilot": return copilotStatus(connection, home: home)
        case "droid": return droidStatus(connection, home: home)
        case "grok": return grokStatus(connection, home: home)
        case "kilo": return kiloStatus(connection, home: home)
        case "kimi": return kimiStatus(connection, home: home)
        case "mastracode": return mastracodeStatus(connection, home: home)
        case "qwen": return qwenStatus(connection, home: home)
        default: return .notConfigured
        }
    }

    @discardableResult
    static func connect(_ h: AIHarness, connection: HarnessConnection,
                        home: URL? = nil) throws -> String {
        switch h.id {
        case "claude": return try claudeConnect(connection, home: home)
        case "codex": return try codexConnect(connection, home: home)
        case "pi": return try piConnect(connection, home: home)
        case "omp": return try ompConnect(connection, home: home)
        case "hermes": return try hermesConnect(h, connection: connection, home: home)
        case "opencode": return try opencodeConnect(connection, home: home)
        case "copilot": return try copilotConnect(connection, home: home)
        case "droid": return try droidConnect(connection, home: home)
        case "grok": return try grokConnect(connection, home: home)
        case "kilo": return try kiloConnect(connection, home: home)
        case "kimi": return try kimiConnect(connection, home: home)
        case "mastracode": return try mastracodeConnect(connection, home: home)
        case "qwen": return try qwenConnect(connection, home: home)
        default: throw NSError(domain: "HarnessConnector", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unknown harness \(h.id)"])
        }
    }

    // MARK: - Shared helpers

    private static func homeDir(_ home: URL?) -> URL {
        home ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Strips `//` and `/* */` comments outside string literals, so JSONC
    /// (pi's and OpenCode's config files may carry them) parses as JSON.
    static func stripJSONComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i = text.index(after: i)
            } else if c == "\"" {
                inString = true
                out.append(c)
                i = text.index(after: i)
            } else if c == "/" ,
                      i < text.index(before: text.endIndex),
                      text[text.index(after: i)] == "/" {
                // Line comment: drop to the newline.
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
            } else if c == "/" ,
                      i < text.index(before: text.endIndex),
                      text[text.index(after: i)] == "*" {
                i = text.index(after: text.index(after: i))
                while i < text.endIndex {
                    if text[i] == "*" ,
                       i < text.index(before: text.endIndex),
                       text[text.index(after: i)] == "/" {
                        i = text.index(after: text.index(after: i))
                        break
                    }
                    i = text.index(after: i)
                }
            } else {
                out.append(c)
                i = text.index(after: i)
            }
        }
        return out
    }

    /// Parses a JSON object; `jsonc` tolerates comments (first strict, then
    /// with them stripped).
    private static func jsonObject(_ text: String, jsonc: Bool,
                                   invalid: String) throws -> [String: Any] {
        func parse(_ s: String) -> [String: Any]? {
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let d = obj as? [String: Any] else { return nil }
            return d
        }
        if let d = parse(text) { return d }
        guard jsonc, let d = parse(stripJSONComments(text)) else {
            throw NSError(domain: "HarnessConnector", code: 2,
                userInfo: [NSLocalizedDescriptionKey: invalid])
        }
        return d
    }

    /// Writes `text` to `path` atomically (temp file + replace), creating
    /// the parent directory when missing.
    private static func writeAtomic(_ path: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: path, options: [.atomic])
    }

    private static func prettyJSON(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Double-quotes a TOML string value.
    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A YAML scalar: plain where safe, else double-quoted.
    private static func yamlScalar(_ s: String) -> String {
        let safe = s.range(of: #"[A-Za-z0-9._/-]+"#, options: .regularExpression)
        if let safe, safe == s.startIndex..<s.endIndex, !s.isEmpty {
            // Don't leave a bare scalar that YAML would read as another type.
            if s == "true" || s == "false" || s == "null" || s == "yes" || s == "no"
                || Int(s) != nil || Double(s) != nil {
                return tomlString(s)
            }
            return s
        }
        return tomlString(s)
    }

    /// The exact line range of a `[table]` block (header to the next
    /// column-0 `[` line or a blank line, or EOF), or nil when absent.
    private static func tomlTableRange(_ table: String,
                                       in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0 == table }) else {
            return nil
        }
        var i = start + 1
        while i < lines.count, !lines[i].hasPrefix("["), !lines[i].isEmpty {
            i += 1
        }
        return start..<i
    }

    /// A TOML key: bare when its characters allow it, else a quoted basic
    /// string (served model ids carry slashes and colons).
    private static func tomlKey(_ s: String) -> String {
        let bare = s.range(of: #"[A-Za-z0-9_-]+"#, options: .regularExpression)
        guard let bare, bare == s.startIndex..<s.endIndex else {
            return tomlString(s)
        }
        return s
    }

    /// The scalar value of `key` in a table block's lines: surrounding
    /// quotes and a trailing comment stripped; nil when the key is absent.
    /// Managed values never carry `#`, so comment stripping is plain.
    private static func tomlValue(_ key: String, in block: [String]) -> String? {
        guard let line = block.first(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix(key + "=") || t.hasPrefix(key + " =")
        }), let eq = line.firstIndex(of: "=") else { return nil }
        var v = line[line.index(after: eq)...]
        if let hash = v.firstIndex(of: "#") { v = v[..<hash] }
        v = v.drop(while: { $0 == " " || $0 == "\t" })
        if v.hasPrefix("\"") , let close = v.lastIndex(of: "\"") {
            v = v[v.index(after: v.startIndex)..<close]
        }
        return String(v)
    }

    /// The value of `key` in a 2-space-indented mapping block of `lines`
    /// starting after `blockStart`; nil when the key is absent. Surrounding
    /// quotes and a trailing comment are stripped.
    private static func yamlValue(_ key: String, indent: Int, in lines: [String],
                                  after blockStart: Int) -> String? {
        let prefix = String(repeating: " ", count: indent) + key + ":"
        let start = blockStart >= 0 ? blockStart + 1 : 0
        guard let idx = lines[start...].firstIndex(where: {
            $0.hasPrefix(prefix) || $0.hasPrefix(prefix + " ")
        }) else { return nil }
        var v = lines[idx].dropFirst(prefix.count)
        v = v.drop(while: { $0 == " " })
        if let hash = v.firstIndex(of: "#") { v = v[..<hash] }
        v = v.drop(while: { $0 == " " || $0 == "\t" })
        if v.hasPrefix("\"") , let close = v.lastIndex(of: "\"") {
            v = v[v.index(after: v.startIndex)..<close]
        }
        return String(v)
    }

    /// A parsed config file: `object` nil when the file is absent, `map`
    /// the sub-map the caller is merging (empty when unset).
    private struct ParsedConfig {
        let object: [String: Any]?
        let map: [String: Any]
    }

    // MARK: - claude

    private static func claudeSettingsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".claude/settings.json")
    }

    private static func claudeEnv(_ home: URL?) -> Result<ParsedConfig, Error> {
        let url = claudeSettingsURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(ParsedConfig(object: nil, map: [:]))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: false,
                invalid: "Invalid Claude settings.json: \(url.path)")
            return .success(ParsedConfig(object: obj,
                                         map: obj["env"] as? [String: Any] ?? [:]))
        } catch { return .failure(error) }
    }

    private static func claudeStatus(_ c: HarnessConnection,
                                     home: URL?) -> HarnessStatus {
        let envResult = claudeEnv(home)
        guard case .success(let parsed) = envResult else {
            return .unreadable("settings.json is not valid JSON")
        }
        guard let url = parsed.map["ANTHROPIC_BASE_URL"] as? String, !url.isEmpty
        else { return .notConfigured }
        return url == c.baseUrl ? .connected : .elsewhere(url)
    }

    private static func claudeConnect(_ c: HarnessConnection,
                                      home: URL?) throws -> String {
        switch claudeEnv(home) {
        case .failure(let error):
            throw error
        case .success(let parsed):
            var settings = parsed.object ?? [:]
            var e = parsed.map
            e["ANTHROPIC_BASE_URL"] = c.baseUrl
            e["ANTHROPIC_AUTH_TOKEN"] = "local"
            for key in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                        "ANTHROPIC_DEFAULT_SONNET_MODEL",
                        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                        "ANTHROPIC_SMALL_FAST_MODEL"] {
                e[key] = c.model
            }
            e["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(c.context)
            e["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(c.context)
            for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                        "CLAUDE_CODE_USE_FOUNDRY"] {
                e[key] = "0"
            }
            // A stored API key would steer Claude Code back to the cloud.
            e.removeValue(forKey: "ANTHROPIC_API_KEY")
            settings["env"] = e
            try writeAtomic(claudeSettingsURL(home), prettyJSON(settings))
            return "settings.json env → \(c.baseUrl)"
        }
    }

    // MARK: - codex

    private static func codexConfigURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".codex/config.toml")
    }

    /// Splits `lines` into the top-level region (before the first column-0
    /// `[table]` header) and the rest.
    private static func codexTopLevelEnd(_ lines: [String]) -> Int {
        lines.firstIndex { $0.hasPrefix("[") } ?? lines.count
    }

    /// The line range of `[table]`'s block (header to the next column-0
    /// line, or EOF), or nil when absent.
    private static func codexTableRange(_ table: String,
                                        in lines: [String]) -> Range<Int>? {
        let header = "[model_providers.\(table)]"
        guard let start = lines.firstIndex(where: { $0 == header }) else {
            return nil
        }
        var end = lines.count
        var i = start + 1
        while i < lines.count, !lines[i].hasPrefix("["), !lines[i].isEmpty {
            i += 1
        }
        end = i
        return start..<end
    }

    private static func codexStatus(_ c: HarnessConnection,
                                    home: URL?) -> HarnessStatus {
        let url = codexConfigURL(home)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .notConfigured }
        let lines = text.components(separatedBy: "\n")
        let topEnd = codexTopLevelEnd(lines)
        func topLevelValue(_ key: String) -> String? {
            guard let idx = lines[..<topEnd].firstIndex(
                where: { $0.hasPrefix(key + " ") || $0.hasPrefix(key + "=") }),
                let eq = lines[idx].firstIndex(of: "=") else { return nil }
            var v = lines[idx][lines[idx].index(after: eq)...]
            v = v.drop(while: { $0 == " " || $0 == "\t" })
            if v.hasPrefix("\"") , let close = v.lastIndex(of: "\"") {
                v = v[v.index(after: v.startIndex)..<close]
            }
            return String(v)
        }
        // Follow the pointer: the harness points where model_provider
        // points, whichever splash* table that names.
        guard let selected = topLevelValue("model_provider"),
              selected.hasPrefix("splash"),
              let range = codexTableRange(selected, in: lines)
        else { return .notConfigured }
        var base: String?
        for line in lines[range] where line.hasPrefix("base_url") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var v = line[line.index(after: eq)...]
            v = v.drop(while: { $0 == " " || $0 == "\t" })
            if v.hasPrefix("\"") , let close = v.lastIndex(of: "\"") {
                v = v[v.index(after: v.startIndex)..<close]
            }
            base = String(v)
            break
        }
        guard let base else { return .notConfigured }
        return base == c.endpoint ? .connected : .elsewhere(base)
    }

    private static func codexConnect(_ c: HarnessConnection,
                                     home: URL?) throws -> String {
        let url = codexConfigURL(home)
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n")
        if lines.isEmpty { lines = [""] }
        // Drop the single trailing empty line of a newline-terminated file
        // while we rebuild; we re-append the final newline at the end.
        if lines.last == "" { lines.removeLast() }

        let table = "[model_providers.\(c.providerName)]"
        let scalars: [(String, String)] = [
            ("model", tomlString(c.model)),
            ("model_provider", tomlString(c.providerName)),
            ("web_search", tomlString("disabled")),
            ("model_context_window", String(c.context)),
            ("model_auto_compact_token_limit", String(c.context * 9 / 10)),
        ]
        let topEnd = codexTopLevelEnd(lines)
        var inserts: [String] = []
        for (key, value) in scalars {
            if let idx = lines[..<topEnd].firstIndex(where: {
                $0.hasPrefix(key + " ") || $0.hasPrefix(key + "=")
            }) {
                lines[idx] = "\(key) = \(value)"
            } else {
                inserts.append("\(key) = \(value)")
            }
        }
        if !inserts.isEmpty {
            lines.insert(contentsOf: inserts, at: topEnd)
        }
        // Drop stale splash provider tables so the config points at one
        // server.
        var stale: [Range<Int>] = []
        for line in lines where line.hasPrefix("[model_providers.")
            && line.hasSuffix("]") {
            let name = String(line.dropFirst("[model_providers.".count)
                              .dropLast())
            if name.hasPrefix("splash"), name != c.providerName,
               let range = codexTableRange(name, in: lines) {
                stale.append(range)
            }
        }
        stale.sort { $0.lowerBound > $1.lowerBound }
        for r in stale { lines.removeSubrange(r) }

        // Replace or append the provider table.
        let block = [table,
                     "name = \"Splash\"",
                     "base_url = \(tomlString(c.endpoint))",
                     "wire_api = \"responses\""]
        if let range = codexTableRange(c.providerName, in: lines) {
            lines.replaceSubrange(range, with: block)
        } else {
            lines += ["", table, "name = \"Splash\"",
                      "base_url = \(tomlString(c.endpoint))",
                      "wire_api = \"responses\""]
        }
        try writeAtomic(url, lines.joined(separator: "\n") + "\n")
        return "config.toml → model_provider \(c.providerName), \(c.endpoint)"
    }

    // MARK: - pi

    private static func piModelsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".pi/agent/models.json")
    }

    private static func piProviders(_ home: URL?)
        -> Result<ParsedConfig, Error> {
        let url = piModelsURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(ParsedConfig(object: [:], map: [:]))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: true,
                invalid: "Invalid Pi models.json: \(url.path)")
            return .success(ParsedConfig(object: obj,
                                         map: obj["providers"] as? [String: Any] ?? [:]))
        } catch { return .failure(error) }
    }

    private static func piStatus(_ c: HarnessConnection,
                                 home: URL?) -> HarnessStatus {
        let result = piProviders(home)
        guard case .success(let parsed) = result else {
            return .unreadable("models.json is not valid JSON")
        }
        let providers = parsed.map
        var fallback: String?
        for (name, value) in providers where name.hasPrefix("splash") {
            guard let entry = value as? [String: Any],
                  let base = entry["baseUrl"] as? String else { continue }
            if base == c.endpoint { return .connected }
            if fallback == nil { fallback = base }
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    private static func piConnect(_ c: HarnessConnection,
                                  home: URL?) throws -> String {
        let result = piProviders(home)
        guard case .success(let parsed) = result else {
            if case .failure(let error) = result { throw error }
            fatalError("piProviders: unexpected empty result")
        }
        var settings = parsed.object!
        var p = parsed.map
        // The app owns the splash namespace: stale splash* providers from
        // an earlier port would keep the harness pointing at two servers.
        for key in p.keys
            where key.hasPrefix("splash") && key != c.providerName {
            p.removeValue(forKey: key)
        }
        let input = c.modalities.contains("image") ? ["text", "image"] : ["text"]
        p[c.providerName] = [
            "baseUrl": c.endpoint,
            "api": "openai-completions",
            "apiKey": "local",
            "models": [[
                "id": c.model,
                "reasoning": true,
                "thinkingLevelMap": ["off": "none"],
                "input": input,
                "contextWindow": c.context,
                "maxTokens": 32768,
            ]],
        ]
        settings["providers"] = p
        try writeAtomic(piModelsURL(home), prettyJSON(settings))
        return "models.json provider \(c.providerName) → \(c.endpoint)"
    }

    // MARK: - omp

    private static func ompModelsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".omp/agent/models.yml")
    }

    /// The provider block of `name` (2-space indent) in a `providers:`
    /// region: its header line and the range it occupies (to the next
    /// non-blank line with less indent, keeping trailing blanks out).
    private static func ompBlock(_ name: String, in lines: [String]) -> (Int, Range<Int>)? {
        guard let prov = lines.firstIndex(where: {
            $0 == "providers:" || $0.hasPrefix("providers:#")
        }) else { return nil }
        let header = "  \(name):"
        guard let start = lines.firstIndex(where: {
            $0 == header || $0.hasPrefix(header + " ") || $0.hasPrefix(header + "\t")
        }), start > prov else { return nil }
        var end = lines.count
        var i = start + 1
        while i < lines.count {
            let t = lines[i]
            let indent = t.prefix { $0 == " " }.count
            if !t.isEmpty && indent < 2 { end = i; break }
            i += 1
        }
        // Back over trailing blank lines so a blank after the block survives.
        while end > start + 1, lines[end - 1].isEmpty { end -= 1 }
        return (prov, start..<end)
    }

    /// Where a new provider block goes in a `providers:` region (or the
    /// file end); nil when there is no `providers:` key at all.
    private static func ompInsertionIndex(in lines: [String]) -> Int? {
        guard let prov = lines.firstIndex(where: {
            $0 == "providers:" || $0.hasPrefix("providers:#")
        }) else { return nil }
        var end = lines.count
        var i = prov + 1
        while i < lines.count {
            let t = lines[i]
            let indent = t.prefix { $0 == " " }.count
            if !t.isEmpty && indent < 2 { end = i; break }
            i += 1
        }
        var pos = end
        while pos > prov + 1, lines[pos - 1].isEmpty { pos -= 1 }
        return pos
    }

    private static func ompConnect(_ c: HarnessConnection,
                                   home: URL?) throws -> String {
        let url = ompModelsURL(home)
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n")
        if lines.isEmpty { lines = [""] }
        if lines.last == "" { lines.removeLast() }

        let input = c.modalities.contains("image") ? "[text, image]" : "[text]"
        let block = [
            "  \(c.providerName):",
            "    baseUrl: \(c.endpoint)",
            "    api: openai-completions",
            "    auth: none",
            "    discovery:",
            "      type: openai-models-list",
            "    modelOverrides:",
            "      \(yamlScalar(c.model)):",
            "        input: \(input)",
            "        contextWindow: \(c.context)",
            "        maxContextWindow: \(c.context)",
        ]
        // Drop stale splash provider blocks so the config points at one
        // server.
        if let prov = lines.firstIndex(where: {
            $0 == "providers:" || $0.hasPrefix("providers:#")
        }) {
            var stale: [Range<Int>] = []
            var j = prov + 1
            while j < lines.count {
                let t = lines[j]
                let indent = t.prefix { $0 == " " }.count
                if !t.isEmpty && indent < 2 { break }
                if t.hasPrefix("  "), !t.hasPrefix("    ") {
                    let name = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ":", with: "")
                    if name.hasPrefix("splash"), name != c.providerName,
                       let (_, range) = ompBlock(name, in: lines) {
                        stale.append(range)
                    }
                }
                j += 1
            }
            stale.sort { $0.lowerBound > $1.lowerBound }
            for r in stale { lines.removeSubrange(r) }
        }
        if let (_, range) = ompBlock(c.providerName, in: lines) {
            lines.replaceSubrange(range, with: block)
        } else if let pos = ompInsertionIndex(in: lines) {
            lines.insert(contentsOf: block, at: pos)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += ["providers:"] + block
        }
        try writeAtomic(url, lines.joined(separator: "\n") + "\n")
        return "models.yml provider \(c.providerName) → \(c.endpoint) (models listed from /v1/models)"
    }

    private static func ompStatus(_ c: HarnessConnection,
                                  home: URL?) -> HarnessStatus {
        let url = ompModelsURL(home)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .notConfigured }
        let lines = text.components(separatedBy: "\n")
        guard let prov = lines.firstIndex(where: {
            $0 == "providers:" || $0.hasPrefix("providers:#")
        }) else { return .notConfigured }
        var fallback: String?
        var i = prov + 1
        while i < lines.count {
            let t = lines[i]
            let indent = t.prefix { $0 == " " }.count
            if !t.isEmpty && indent < 2 { break }
            if t.hasPrefix("  ") && !t.hasPrefix("    ") {
                let name = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ":", with: "")
                if name.hasPrefix("splash") {
                    var j = i + 1
                    while j < lines.count {
                        let u = lines[j]
                        let uIndent = u.prefix { $0 == " " }.count
                        if !u.isEmpty && uIndent < 4 { break }
                        if u.hasPrefix("    baseUrl:") {
                            let v = yamlValue("baseUrl", indent: 4,
                                              in: lines, after: j - 1)
                            if let v, v == c.endpoint { return .connected }
                            if let v, fallback == nil { fallback = v }
                            break
                        }
                        j += 1
                    }
                }
            }
            i += 1
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    // MARK: - hermes

    private static func hermesRoot(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".hermes")
    }

    /// The `model:` block of a profile config.yaml: its header line and the
    /// range of the 2-space-indented lines under it (to the next non-blank
    /// column-0 line).
    private static func hermesModelBlock(in lines: [String]) -> (Int, Range<Int>)? {
        guard let start = lines.firstIndex(where: {
            $0 == "model:" || $0.hasPrefix("model:#")
        }) else { return nil }
        var end = lines.count
        var i = start + 1
        while i < lines.count {
            let t = lines[i]
            let indent = t.prefix { $0 == " " }.count
            if !t.isEmpty && indent < 2 { end = i; break }
            i += 1
        }
        while end > start + 1, lines[end - 1].isEmpty { end -= 1 }
        return (start, start + 1..<end)
    }

    private static func hermesProfileStatus(_ home: URL,
                                            connection: HarnessConnection)
        -> HarnessStatus? {
        let profiles = hermesRoot(home).appendingPathComponent("profiles")
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: profiles.path) else { return nil }
        var fallback: String?
        for name in names.sorted() {
            let cfg = profiles.appendingPathComponent(name)
                .appendingPathComponent("config.yaml")
            guard let text = try? String(contentsOf: cfg, encoding: .utf8)
            else { continue }
            let lines = text.components(separatedBy: "\n")
            guard let (_, range) = hermesModelBlock(in: lines),
                  let provider = yamlValue("provider", indent: 2,
                                           in: lines, after: range.lowerBound - 1),
                  provider == "custom" else { continue }
            guard let base = yamlValue("base_url", indent: 2,
                                       in: lines, after: range.lowerBound - 1)
            else { continue }
            if base == connection.endpoint { return .connected }
            if fallback == nil { fallback = base }
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    private static func hermesStatus(_ c: HarnessConnection,
                                     home: URL?) -> HarnessStatus {
        hermesProfileStatus(homeDir(home), connection: c) ?? .notConfigured
    }

    private static func hermesProfileURL(_ home: URL,
                                         name: String) -> URL {
        hermesRoot(home).appendingPathComponent("profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("config.yaml")
    }

    /// Runs `<hermes> profile create <name> --no-alias`, as a user would —
    /// Hermes seeds the profile's files and lifts the mark `profile delete`
    /// leaves, without which Hermes refuses the profile.
    private static func hermesCreateProfile(_ binary: String, _ home: URL,
                                            name: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["profile", "create", name, "--no-alias"]
        p.environment = SplashProcess.childEnvironment()
        p.standardInput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.standardOutput = err
        do { try p.run() }
        catch { throw NSError(domain: "HarnessConnector", code: 3,
            userInfo: [NSLocalizedDescriptionKey:
                "Couldn't run \(binary): \(error.localizedDescription)"]) }
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning {
            p.terminate()
            throw NSError(domain: "HarnessConnector", code: 4,
                userInfo: [NSLocalizedDescriptionKey:
                    "hermes profile create \(name) timed out"])
        }
        let homeDir = hermesRoot(home).appendingPathComponent("profiles")
            .appendingPathComponent(name)
        if p.terminationStatus != 0, !FileManager.default.fileExists(atPath: homeDir.path) {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let tail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(500)
            throw NSError(domain: "HarnessConnector", code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "hermes profile create \(name) failed: \(tail)"])
        }
    }

    private static func hermesConnect(_ h: AIHarness,
                                      connection c: HarnessConnection,
                                      home: URL?) throws -> String {
        let home = homeDir(home)
        let profiles = hermesRoot(home).appendingPathComponent("profiles")
        let profileDir = profiles.appendingPathComponent(c.providerName)
        var created = false
        if !FileManager.default.fileExists(atPath: profileDir.path) {
            guard let binary = SplashInstaller.locate(h.binary) else {
                throw NSError(domain: "HarnessConnector", code: 6,
                    userInfo: [NSLocalizedDescriptionKey:
                        "hermes is no longer on the PATH"])
            }
            try hermesCreateProfile(binary, home, name: c.providerName)
            created = true
        }
        let url = hermesProfileURL(home, name: c.providerName)
        var lines: [String] = []
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
        }
        let output = min(32768, max(1, c.context / 4))
        let block = [
            "model:",
            "  default: \(yamlScalar(c.model))",
            "  provider: custom",
            "  base_url: \(c.endpoint)",
            "  api_key: local",
            "  api_mode: chat_completions",
            "  supports_vision: \(c.modalities.contains("image") ? "true" : "false")",
            "  context_length: \(c.context)",
            "  max_tokens: \(output)",
        ]
        if let (headerIdx, range) = hermesModelBlock(in: lines) {
            // Keep keys of the model map we don't manage; ours are replaced.
            let managed = ["default", "provider", "base_url", "api_key",
                           "api_mode", "supports_vision", "context_length",
                           "max_tokens"]
            var kept: [String] = []
            for line in lines[range] where !line.isEmpty {
                guard line.hasPrefix("  "), !line.hasPrefix("    "),
                      let colon = line.firstIndex(of: ":"),
                      !managed.contains(line[line.startIndex..<colon]
                          .trimmingCharacters(in: .whitespaces))
                else { continue }
                kept.append(line)
            }
            let tail = lines[range.upperBound...]
            lines = Array(lines[..<headerIdx]) + block + kept + Array(tail)
        } else {
            if !lines.isEmpty, !(lines.last?.isEmpty ?? true) {
                lines.append("")
            }
            lines += block
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(url, lines.joined(separator: "\n") + "\n")
        return "profile \(c.providerName) → \(c.endpoint)"
            + (created ? " (profile created)" : "")
    }

    // MARK: - opencode & kilo (one config shape, two files)

    /// Kilo's config is OpenCode's (its schema is opencode's): the same
    /// provider merge, its own file under ~/.config/kilo/.
    private static func opencodeFamilyURL(_ home: URL?, dir: String,
                                          base: String) -> URL {
        let d = homeDir(home).appendingPathComponent(dir)
        let json = d.appendingPathComponent(base + ".json")
        let jsonc = d.appendingPathComponent(base + ".jsonc")
        let fm = FileManager.default
        if fm.fileExists(atPath: json.path) { return json }
        if fm.fileExists(atPath: jsonc.path) { return jsonc }
        return json
    }

    private static func opencodeFamilyProviders(_ home: URL?, dir: String,
                                                base: String)
        -> Result<ParsedConfig, Error> {
        let url = opencodeFamilyURL(home, dir: dir, base: base)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(ParsedConfig(object: [:], map: [:]))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: true,
                invalid: "Invalid \(base).json config: \(url.path)")
            return .success(ParsedConfig(object: obj,
                                         map: obj["provider"] as? [String: Any] ?? [:]))
        } catch { return .failure(error) }
    }

    private static func opencodeFamilyStatus(_ c: HarnessConnection,
                                             home: URL?, dir: String,
                                             base: String) -> HarnessStatus {
        let result = opencodeFamilyProviders(home, dir: dir, base: base)
        guard case .success(let parsed) = result else {
            return .unreadable("\(base).json is not valid JSON")
        }
        let providers = parsed.map
        var fallback: String?
        for (name, value) in providers where name.hasPrefix("splash") {
            guard let entry = value as? [String: Any],
                  let options = entry["options"] as? [String: Any],
                  let base2 = options["baseURL"] as? String else { continue }
            if base2 == c.endpoint { return .connected }
            if fallback == nil { fallback = base2 }
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    private static func opencodeFamilyConnect(_ c: HarnessConnection,
                                              home: URL?, dir: String,
                                              base: String) throws -> String {
        let result = opencodeFamilyProviders(home, dir: dir, base: base)
        guard case .success(let parsed) = result else {
            if case .failure(let error) = result { throw error }
            fatalError("opencodeFamilyProviders: unexpected empty result")
        }
        var cfg = parsed.object!
        let served = "\(c.providerName)/\(c.model)"
        cfg["model"] = served
        cfg["small_model"] = served
        var agents = cfg["agent"] as? [String: Any] ?? [:]
        for agent in ["build", "plan", "general", "explore", "title", "compaction"] {
            var a = agents[agent] as? [String: Any] ?? [:]
            a["model"] = served
            agents[agent] = a
        }
        cfg["agent"] = agents
        var p = parsed.map
        // The app owns the splash namespace: stale splash* providers from
        // an earlier port would keep the harness pointing at two servers.
        for key in p.keys
            where key.hasPrefix("splash") && key != c.providerName {
            p.removeValue(forKey: key)
        }
        let output = min(32768, max(1, c.context / 4))
        var variants: [String: [String: String]] = [:]
        for effort in ["none", "low", "medium", "high", "xhigh"] {
            variants[effort] = ["reasoningEffort": effort]
        }
        p[c.providerName] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "Splash",
            "options": ["baseURL": c.endpoint, "apiKey": "local"],
            // Model names are the keys.
            "models": [
                c.model: [
                    "name": c.model,
                    "reasoning": true,
                    "variants": variants,
                    // Attachments are images and PDFs.
                    "attachment": c.modalities != ["text"],
                    "modalities": ["input": c.modalities, "output": ["text"]],
                    // The shared window includes the output allowance.
                    "limit": ["context": c.context,
                              "input": max(1, c.context - output),
                              "output": output],
                ],
            ],
        ]
        cfg["provider"] = p
        try writeAtomic(opencodeFamilyURL(home, dir: dir, base: base),
                        prettyJSON(cfg))
        return "\(base).json provider \(c.providerName) → \(c.endpoint)"
    }

    private static func opencodeStatus(_ c: HarnessConnection,
                                       home: URL?) -> HarnessStatus {
        opencodeFamilyStatus(c, home: home, dir: ".config/opencode",
                             base: "opencode")
    }

    private static func opencodeConnect(_ c: HarnessConnection,
                                        home: URL?) throws -> String {
        try opencodeFamilyConnect(c, home: home, dir: ".config/opencode",
                                  base: "opencode")
    }

    private static func kiloStatus(_ c: HarnessConnection,
                                   home: URL?) -> HarnessStatus {
        opencodeFamilyStatus(c, home: home, dir: ".config/kilo", base: "kilo")
    }

    private static func kiloConnect(_ c: HarnessConnection,
                                    home: URL?) throws -> String {
        try opencodeFamilyConnect(c, home: home, dir: ".config/kilo",
                                  base: "kilo")
    }

    // MARK: - copilot

    private static func copilotProvidersURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".copilot/providers.json")
    }

    /// nil object when the file is absent (created fresh); the two arrays
    /// empty when unset.
    private static func copilotParse(_ home: URL?)
        -> Result<([String: Any]?, [[String: Any]], [[String: Any]]), Error> {
        let url = copilotProvidersURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success((nil, [], []))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: false,
                invalid: "Invalid Copilot providers.json: \(url.path)")
            return .success((obj, obj["providers"] as? [[String: Any]] ?? [],
                             obj["models"] as? [[String: Any]] ?? []))
        } catch { return .failure(error) }
    }

    private static func copilotStatus(_ c: HarnessConnection,
                                      home: URL?) -> HarnessStatus {
        let parsed = copilotParse(home)
        switch parsed {
        case .failure:
            return .unreadable("providers.json is not valid JSON")
        case .success(let (_, providers, _)):
            var fallback: String?
            for p in providers
                where (p["name"] as? String)?.hasPrefix("splash") == true {
                guard let base = p["baseUrl"] as? String else { continue }
                if base == c.endpoint { return .connected }
                if fallback == nil { fallback = base }
            }
            return fallback.map { .elsewhere($0) } ?? .notConfigured
        }
    }

    private static func copilotConnect(_ c: HarnessConnection,
                                       home: URL?) throws -> String {
        let parsed = copilotParse(home)
        switch parsed {
        case .failure(let error):
            throw error
        case .success(let (obj, providers, models)):
            var settings = obj ?? [:]
            // The app owns the splash namespace: stale providers and their
            // models from an earlier port are dropped.
            var ps = providers
            ps.removeAll {
                ($0["name"] as? String)?.hasPrefix("splash") == true
            }
            ps.append([
                "name": c.providerName,
                "type": "openai",
                "baseUrl": c.endpoint,
                "apiKey": "local",
            ])
            var ms = models
            ms.removeAll {
                ($0["provider"] as? String)?.hasPrefix("splash") == true
            }
            let output = min(32768, max(1, c.context / 4))
            ms.append([
                "id": c.model,
                "provider": c.providerName,
                "maxPromptTokens": max(1, c.context - output),
                "maxContextWindowTokens": c.context,
                "maxOutputTokens": output,
                "capabilities": ["supports": [
                    "vision": c.modalities.contains("image"),
                    "toolCalls": true,
                ]],
            ])
            settings["providers"] = ps
            settings["models"] = ms
            try writeAtomic(copilotProvidersURL(home), prettyJSON(settings))
            return "providers.json provider \(c.providerName) → \(c.endpoint) "
                + "(select \(c.providerName)/\(c.model) in /model)"
        }
    }

    // MARK: - droid

    private static func droidSettingsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".factory/settings.json")
    }

    private static func droidParse(_ home: URL?)
        -> Result<([String: Any]?, [[String: Any]]), Error> {
        let url = droidSettingsURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success((nil, []))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: false,
                invalid: "Invalid Droid settings.json: \(url.path)")
            return .success((obj,
                             obj["customModels"] as? [[String: Any]] ?? []))
        } catch { return .failure(error) }
    }

    private static func droidStatus(_ c: HarnessConnection,
                                    home: URL?) -> HarnessStatus {
        let parsed = droidParse(home)
        switch parsed {
        case .failure:
            return .unreadable("settings.json is not valid JSON")
        case .success(let (_, models)):
            // The app names its entries "\(providerName) · <model>".
            var fallback: String?
            for m in models
                where (m["displayName"] as? String)?.hasPrefix("splash") == true {
                guard let base = m["baseUrl"] as? String else { continue }
                if base == c.endpoint { return .connected }
                if fallback == nil { fallback = base }
            }
            return fallback.map { .elsewhere($0) } ?? .notConfigured
        }
    }

    private static func droidConnect(_ c: HarnessConnection,
                                     home: URL?) throws -> String {
        let parsed = droidParse(home)
        switch parsed {
        case .failure(let error):
            throw error
        case .success(let (obj, models)):
            var settings = obj ?? [:]
            var custom = models
            custom.removeAll {
                ($0["displayName"] as? String)?.hasPrefix("splash") == true
            }
            let output = min(32768, max(1, c.context / 4))
            custom.append([
                "model": c.model,
                "displayName": "\(c.providerName) · \(c.model)",
                "baseUrl": c.endpoint,
                // Some OpenAI-compatible servers want a non-empty key even
                // when they ignore it.
                "apiKey": "local",
                "provider": "generic-chat-completion-api",
                "maxContextLimit": c.context,
                "maxOutputTokens": output,
            ])
            settings["customModels"] = custom
            try writeAtomic(droidSettingsURL(home), prettyJSON(settings))
            return "settings.json custom model \(c.providerName) → \(c.endpoint)"
        }
    }

    // MARK: - grok

    private static func grokConfigURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".grok/config.toml")
    }

    private static func grokStatus(_ c: HarnessConnection,
                                   home: URL?) -> HarnessStatus {
        let url = grokConfigURL(home)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .notConfigured }
        let lines = text.components(separatedBy: "\n")
        var fallback: String?
        for line in lines where line.hasPrefix("[model.")
            && line.hasSuffix("]") {
            let name = String(line.dropFirst("[model.".count).dropLast())
            guard name.hasPrefix("splash") else { continue }
            guard let range = tomlTableRange(line, in: lines),
                  let base = tomlValue("base_url", in: Array(lines[range]))
            else { continue }
            if base == c.endpoint { return .connected }
            if fallback == nil { fallback = base }
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    private static func grokConnect(_ c: HarnessConnection,
                                    home: URL?) throws -> String {
        let url = grokConfigURL(home)
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n")
        if lines.isEmpty { lines = [""] }
        if lines.last == "" { lines.removeLast() }

        // Drop stale splash model tables so the config points at one
        // server.
        var stale: [Range<Int>] = []
        for line in lines where line.hasPrefix("[model.")
            && line.hasSuffix("]") {
            let name = String(line.dropFirst("[model.".count).dropLast())
            if name.hasPrefix("splash"), name != c.providerName,
               let range = tomlTableRange(line, in: lines) {
                stale.append(range)
            }
        }
        stale.sort { $0.lowerBound > $1.lowerBound }
        for r in stale { lines.removeSubrange(r) }

        let output = min(32768, max(1, c.context / 4))
        let header = "[model.\(c.providerName)]"
        let block = [
            header,
            "model = \(tomlString(c.model))",
            "base_url = \(tomlString(c.endpoint))",
            "name = \"Splash\"",
            "api_key = \"local\"",
            "api_backend = \"chat_completions\"",
            "context_window = \(c.context)",
            "max_completion_tokens = \(output)",
        ]
        if let range = tomlTableRange(header, in: lines) {
            lines.replaceSubrange(range, with: block)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += block
        }

        // New sessions start on the served model.
        let defaultLine = "default = \(tomlString(c.providerName))"
        if let range = tomlTableRange("[models]", in: lines) {
            let block = Array(lines[range])
            if let idx = block.firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("default=") || t.hasPrefix("default =")
            }) {
                lines[range.lowerBound + idx] = defaultLine
            } else {
                lines.insert(defaultLine, at: range.upperBound)
            }
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += ["[models]", defaultLine]
        }

        try writeAtomic(url, lines.joined(separator: "\n") + "\n")
        return "config.toml model \(c.providerName) → \(c.endpoint)"
    }

    // MARK: - kimi

    private static func kimiConfigURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".kimi/config.toml")
    }

    private static func kimiStatus(_ c: HarnessConnection,
                                   home: URL?) -> HarnessStatus {
        let url = kimiConfigURL(home)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .notConfigured }
        let lines = text.components(separatedBy: "\n")
        var fallback: String?
        for line in lines where line.hasPrefix("[providers.")
            && line.hasSuffix("]") {
            let name = String(line.dropFirst("[providers.".count).dropLast())
            guard name.hasPrefix("splash") else { continue }
            guard let range = tomlTableRange(line, in: lines),
                  let base = tomlValue("base_url", in: Array(lines[range]))
            else { continue }
            if base == c.endpoint { return .connected }
            if fallback == nil { fallback = base }
        }
        return fallback.map { .elsewhere($0) } ?? .notConfigured
    }

    private static func kimiConnect(_ c: HarnessConnection,
                                    home: URL?) throws -> String {
        let url = kimiConfigURL(home)
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        var lines = text.components(separatedBy: "\n")
        if lines.isEmpty { lines = [""] }
        if lines.last == "" { lines.removeLast() }

        // The selected model, at top level (before the first [table]).
        let topEnd = lines.firstIndex { $0.hasPrefix("[") } ?? lines.count
        let defaultLine = "default_model = \(tomlString(c.model))"
        if let idx = lines[..<topEnd].firstIndex(where: {
            $0.hasPrefix("default_model ") || $0.hasPrefix("default_model=")
        }) {
            lines[idx] = defaultLine
        } else {
            lines.insert(defaultLine, at: topEnd)
        }

        // Drop stale splash providers so the config points at one server.
        var stale: [Range<Int>] = []
        for line in lines where line.hasPrefix("[providers.")
            && line.hasSuffix("]") {
            let name = String(line.dropFirst("[providers.".count).dropLast())
            if name.hasPrefix("splash"), name != c.providerName,
               let range = tomlTableRange(line, in: lines) {
                stale.append(range)
            }
        }
        stale.sort { $0.lowerBound > $1.lowerBound }
        for r in stale { lines.removeSubrange(r) }

        let providerHeader = "[providers.\(c.providerName)]"
        let providerBlock = [
            providerHeader,
            "type = \"openai_legacy\"",
            "base_url = \(tomlString(c.endpoint))",
            "api_key = \"local\"",
        ]
        if let range = tomlTableRange(providerHeader, in: lines) {
            lines.replaceSubrange(range, with: providerBlock)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += providerBlock
        }

        // Model entry keyed by the served model id (quoted: it carries
        // slashes and colons). Drop stale entries pointing at another
        // splash provider.
        let modelHeader = "[models.\(tomlKey(c.model))]"
        var staleModels: [Range<Int>] = []
        for line in lines where line.hasPrefix("[models.")
            && line.hasSuffix("]") {
            guard let range = tomlTableRange(line, in: lines),
                  let provider = tomlValue("provider", in: Array(lines[range])),
                  provider.hasPrefix("splash"), provider != c.providerName
            else { continue }
            staleModels.append(range)
        }
        staleModels.sort { $0.lowerBound > $1.lowerBound }
        for r in staleModels { lines.removeSubrange(r) }

        var capabilities = ["thinking"]
        if c.modalities.contains("image") { capabilities.append("image_in") }
        let capList = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        let modelBlock = [
            modelHeader,
            "provider = \(tomlString(c.providerName))",
            "model = \(tomlString(c.model))",
            "max_context_size = \(c.context)",
            "capabilities = [\(capList)]",
        ]
        if let range = tomlTableRange(modelHeader, in: lines) {
            lines.replaceSubrange(range, with: modelBlock)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += modelBlock
        }

        try writeAtomic(url, lines.joined(separator: "\n") + "\n")
        return "config.toml provider \(c.providerName) → \(c.endpoint)"
    }

    // MARK: - mastracode

    private static func mastracodeSettingsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(
            "Library/Application Support/mastracode/settings.json")
    }

    private static func mastracodeParse(_ home: URL?)
        -> Result<([String: Any]?, [[String: Any]]), Error> {
        let url = mastracodeSettingsURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success((nil, []))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: false,
                invalid: "Invalid Mastra Code settings.json: \(url.path)")
            return .success((obj,
                             obj["customProviders"] as? [[String: Any]] ?? []))
        } catch { return .failure(error) }
    }

    private static func mastracodeStatus(_ c: HarnessConnection,
                                         home: URL?) -> HarnessStatus {
        let parsed = mastracodeParse(home)
        switch parsed {
        case .failure:
            return .unreadable("settings.json is not valid JSON")
        case .success(let (_, providers)):
            var fallback: String?
            for p in providers
                where (p["name"] as? String)?.hasPrefix("splash") == true {
                guard let base = p["url"] as? String else { continue }
                if base == c.endpoint { return .connected }
                if fallback == nil { fallback = base }
            }
            return fallback.map { .elsewhere($0) } ?? .notConfigured
        }
    }

    private static func mastracodeConnect(_ c: HarnessConnection,
                                          home: URL?) throws -> String {
        let parsed = mastracodeParse(home)
        switch parsed {
        case .failure(let error):
            throw error
        case .success(let (obj, providers)):
            var settings = obj ?? [:]
            var custom = providers
            custom.removeAll {
                ($0["name"] as? String)?.hasPrefix("splash") == true
            }
            custom.append([
                "name": c.providerName,
                "url": c.endpoint,
                "apiKey": "local",
                "models": [c.model],
            ])
            settings["customProviders"] = custom
            try writeAtomic(mastracodeSettingsURL(home),
                            prettyJSON(settings))
            return "settings.json provider \(c.providerName) → \(c.endpoint) "
                + "(pick the model in /models)"
        }
    }

    // MARK: - qwen

    /// The envKey that marks an app-managed modelProviders entry; the key
    /// value itself sits in the file's own env map, so the config is
    /// self-contained.
    private static let qwenEnvKey = "SPLASH_API_KEY"

    private static func qwenSettingsURL(_ home: URL?) -> URL {
        homeDir(home).appendingPathComponent(".qwen/settings.json")
    }

    private static func qwenParse(_ home: URL?)
        -> Result<([String: Any], [[String: Any]]), Error> {
        let url = qwenSettingsURL(home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(([:], []))
        }
        do {
            let obj = try jsonObject(
                String(contentsOf: url, encoding: .utf8), jsonc: false,
                invalid: "Invalid Qwen settings.json: \(url.path)")
            let openai = ((obj["modelProviders"] as? [String: Any])?["openai"])
                .flatMap { $0 as? [[String: Any]] } ?? []
            return .success((obj, openai))
        } catch { return .failure(error) }
    }

    private static func qwenStatus(_ c: HarnessConnection,
                                   home: URL?) -> HarnessStatus {
        let parsed = qwenParse(home)
        switch parsed {
        case .failure:
            return .unreadable("settings.json is not valid JSON")
        case .success(let (_, entries)):
            var fallback: String?
            for e in entries where e["envKey"] as? String == qwenEnvKey {
                guard let base = e["baseUrl"] as? String else { continue }
                if base == c.endpoint { return .connected }
                if fallback == nil { fallback = base }
            }
            return fallback.map { .elsewhere($0) } ?? .notConfigured
        }
    }

    private static func qwenConnect(_ c: HarnessConnection,
                                    home: URL?) throws -> String {
        let parsed = qwenParse(home)
        switch parsed {
        case .failure(let error):
            throw error
        case .success(let (settings, entries)):
            var cfg = settings
            var env = settings["env"] as? [String: Any] ?? [:]
            env[qwenEnvKey] = "local"
            cfg["env"] = env
            var modelProviders = settings["modelProviders"] as? [String: Any]
                ?? [:]
            var openai = entries.filter {
                ($0["envKey"] as? String) != qwenEnvKey
            }
            openai.append([
                "id": c.model,
                "name": "\(c.model) (Splash)",
                "baseUrl": c.endpoint,
                "envKey": qwenEnvKey,
            ])
            modelProviders["openai"] = openai
            cfg["modelProviders"] = modelProviders
            var model = settings["model"] as? [String: Any] ?? [:]
            model["name"] = c.model
            cfg["model"] = model
            try writeAtomic(qwenSettingsURL(home), prettyJSON(cfg))
            return "settings.json → \(c.model) at \(c.endpoint)"
        }
    }
}

/// Settings-window state for the AI harness field.
final class HarnessModel: ObservableObject {
    /// Every harness the app can connect (the picker lists all of them);
    /// the ones whose binary is on the PATH right now.
    var supported: [AIHarness] { AIHarnesses.all }
    @Published private(set) var installedIDs: Set<String> = []
    @Published var selectedID: String?
    @Published private(set) var status: HarnessStatus = .notConfigured
    @Published private(set) var busy = false
    /// The last connect result (the note on success, the error text on
    /// failure), or a hint when connect isn't possible.
    @Published private(set) var note: String?

    private let connectionProvider: () -> HarnessConnection?

    /// The selected harness's binary is on the PATH.
    var selectedIsInstalled: Bool {
        selected.map { installedIDs.contains($0.id) } ?? false
    }

    init(connectionProvider: @escaping () -> HarnessConnection?) {
        self.connectionProvider = connectionProvider
        rescan()
    }

    var selected: AIHarness? {
        AIHarnesses.all.first { $0.id == selectedID }
    }

    /// Re-checks which harnesses are installed and refreshes the status
    /// of the selected one.
    func rescan() {
        installedIDs = Set(AIHarnesses.installed().map(\.id))
        if selectedID == nil || !AIHarnesses.all.contains(where: { $0.id == selectedID }) {
            // Prefer an installed harness; with none installed the first
            // supported one is selected (shown as "Not installed").
            selectedID = AIHarnesses.all.first(where: { installedIDs.contains($0.id) })?.id
                ?? AIHarnesses.all.first?.id
        }
        refreshStatus()
    }

    /// The user picked a different harness: the status shown belongs to
    /// the previous selection, and the note is the outcome of a connection
    /// attempt against it — re-derive both.
    func selectionChanged() {
        note = nil
        refreshStatus()
    }

    /// Connects the selected harness in the background; a no-op when
    /// nothing is selected, one is running, or no connection is available.
    func connect() {
        guard let sel = selected, !busy else { return }
        guard installedIDs.contains(sel.id) else {
            note = "Install \(sel.name) first — Auto Connect writes its configuration."
            return
        }
        guard let conn = connectionProvider() else {
            note = "Start splash once first — Auto Connect needs the served model's name."
            return
        }
        busy = true
        note = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try HarnessConnector.connect(sel, connection: conn))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.note = switch result {
                case .success(let note): note
                case .failure(let error): error.localizedDescription
                }
                self.refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        let sel = selected
        let installed = sel.map { installedIDs.contains($0.id) } ?? false
        let conn = connectionProvider()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s: HarnessStatus
            if let sel {
                if installed, let conn {
                    s = HarnessConnector.status(sel, connection: conn)
                } else if installed {
                    s = .notConfigured
                } else {
                    s = .notInstalled
                }
            } else {
                s = .notConfigured
            }
            // A faster re-scan may have overtaken this one; drop the result
            // so a slow read of the previous selection can't overwrite the
            // status of the harness the user is now looking at.
            DispatchQueue.main.async {
                guard let self else { return }
                if let sel, self.selectedID != sel.id { return }
                self.status = s
            }
        }
    }
}
