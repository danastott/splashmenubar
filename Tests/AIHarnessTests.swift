import XCTest
@testable import SplashMenuBar

final class AIHarnessTests: XCTestCase {
    private let model = "Qwen3.8-27B-UD-Q4_K_M"
    private let context = 98304
    private let modalities = ["text", "image"]

    private func connection(_ port: Int = 8000) -> HarnessConnection {
        HarnessConnection(port: port, model: model, context: context,
                          modalities: modalities)
    }

    /// A fresh fake home; removed afterwards.
    private func withHome(_ block: (URL) throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("splashmenubar-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home,
            withIntermediateDirectories: true)
        try block(home)
    }

    /// Writes a fixture file, creating the parent directories (a fresh
    /// home has none of them).
    private func seed(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - claude

    func testClaude() throws {
        try withHome { home in
            let claude = AIHarnesses.all.first { $0.id == "claude" }!
            let settings = home.appendingPathComponent(".claude/settings.json")

            // Unconfigured on an empty home.
            XCTAssertEqual(
                HarnessConnector.status(claude, connection: connection(), home: home), .notConfigured)

            // Pre-existing content survives; a stored API key goes away.
            try seed(Data(#"""
            {"env": {"CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
                "ANTHROPIC_API_KEY": "sk-old"},
                "modelOverrides": {"claude-sonnet-4-6": "ollama/qwen3.8:27b-mlx"}}
            """#.utf8), settings)

            let note = try HarnessConnector.connect(claude,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("settings.json"))
            let obj = try readJSON(settings)
            let env = try XCTUnwrap(obj["env"] as? [String: Any])
            XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8000")
            XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "local")
            XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, model)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, model)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, model)
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, model)
            XCTAssertEqual(env["ANTHROPIC_SMALL_FAST_MODEL"] as? String, model)
            XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, "98304")
            XCTAssertEqual(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String, "98304")
            XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"] as? String, "0")
            XCTAssertEqual(env["CLAUDE_CODE_USE_VERTEX"] as? String, "0")
            XCTAssertEqual(env["CLAUDE_CODE_USE_FOUNDRY"] as? String, "0")
            XCTAssertNil(env["ANTHROPIC_API_KEY"])
            XCTAssertEqual(env["CLAUDE_CODE_ATTRIBUTION_HEADER"] as? String, "0")
            XCTAssertNotNil(obj["modelOverrides"])

            XCTAssertEqual(
                HarnessConnector.status(claude, connection: connection(), home: home), .connected)

            // Another port: the config now points elsewhere.
            try HarnessConnector.connect(claude, connection: connection(8001), home: home)
            XCTAssertEqual(
                HarnessConnector.status(claude, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001"))
            // Re-connecting fixes it.
            try HarnessConnector.connect(claude, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(claude, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - codex

    private func codexToml(_ home: URL) -> String {
        (try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"),
                     encoding: .utf8)) ?? ""
    }

    func testCodex() throws {
        try withHome { home in
            let codex = AIHarnesses.all.first { $0.id == "codex" }!

            XCTAssertEqual(
                HarnessConnector.status(codex, connection: connection(), home: home), .notConfigured)

            // Pre-existing content: a top-level key and two tables.
            try seed(Data("""
            notify = ["client"]
            model = "old-model"

            [plugins."a@b"]
            enabled = true

            [mcp_servers.node_repl]
            command = "node_repl"

            """.utf8), home.appendingPathComponent(".codex/config.toml"))

            let note = try HarnessConnector.connect(codex,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("config.toml"))
            let text = codexToml(home)

            // Top-level region (before the first [table]): the key replaced
            // in place, the others added, nothing duplicated.
            let topEnd = text.range(of: "\n[")?.lowerBound ?? text.endIndex
            let top = text[..<topEnd]
            XCTAssertTrue(top.contains("model = \"\(model)\""))
            XCTAssertFalse(top.contains("old-model"))
            XCTAssertTrue(top.contains("model_provider = \"splash\""))
            XCTAssertTrue(top.contains("web_search = \"disabled\""))
            XCTAssertTrue(top.contains("model_context_window = 98304"))
            XCTAssertTrue(top.contains("model_auto_compact_token_limit = 88473"))
            XCTAssertEqual(top.components(separatedBy: "model = ").count - 1, 1)

            // The provider table, and the pre-existing tables survive.
            XCTAssertTrue(text.contains("[model_providers.splash]"))
            XCTAssertTrue(text.contains("name = \"Splash\""))
            XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8000/v1\""))
            XCTAssertTrue(text.contains("wire_api = \"responses\""))
            XCTAssertTrue(text.contains("[mcp_servers.node_repl]"))
            XCTAssertTrue(text.contains("command = \"node_repl\""))
            XCTAssertEqual(text.components(separatedBy: "[model_providers.splash]").count
                           - 1, 1)

            XCTAssertEqual(
                HarnessConnector.status(codex, connection: connection(), home: home), .connected)

            // A stale table is replaced, not duplicated.
            try HarnessConnector.connect(codex, connection: connection(8001), home: home)
            let text2 = codexToml(home)
            XCTAssertEqual(text2.components(separatedBy: "[model_providers.splash-8001]").count
                           - 1, 1)
            XCTAssertTrue(text2.contains("base_url = \"http://127.0.0.1:8001/v1\""))
            XCTAssertEqual(
                HarnessConnector.status(codex, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(codex, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(codex, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - pi

    func testPi() throws {
        try withHome { home in
            let pi = AIHarnesses.all.first { $0.id == "pi" }!
            let models = home.appendingPathComponent(".pi/agent/models.json")

            XCTAssertEqual(
                HarnessConnector.status(pi, connection: connection(), home: home), .notConfigured)

            // A commented (JSONC) file with another provider survives.
            try seed(Data("""
            {
              // Mirrored from omp's models.yml
              "providers": {
                "omlx": {
                  "baseUrl": "http://127.0.0.1:11434/v1",
                  "api": "openai-completions",
                  "apiKey": "none",
                  "models": []
                }
              }
            }
            """.utf8), models)

            let note = try HarnessConnector.connect(pi, connection: connection(), home: home)
            XCTAssertTrue(note.contains("models.json"))
            let obj = try readJSON(models)
            let providers = try XCTUnwrap(obj["providers"] as? [String: Any])
            XCTAssertEqual((providers["omlx"] as? [String: Any])?["baseUrl"] as? String,
                           "http://127.0.0.1:11434/v1")
            let splash = try XCTUnwrap(providers["splash"] as? [String: Any])
            XCTAssertEqual(splash["baseUrl"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(splash["api"] as? String, "openai-completions")
            XCTAssertEqual(splash["apiKey"] as? String, "local")
            let entries = try XCTUnwrap(splash["models"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0]["id"] as? String, model)
            XCTAssertEqual(entries[0]["reasoning"] as? Bool, true)
            XCTAssertEqual(entries[0]["contextWindow"] as? Int, 98304)
            XCTAssertEqual(entries[0]["maxTokens"] as? Int, 32768)
            XCTAssertEqual(entries[0]["input"] as? [String], ["text", "image"])
            XCTAssertEqual((entries[0]["thinkingLevelMap"] as? [String: String])?["off"],
                           "none")

            XCTAssertEqual(
                HarnessConnector.status(pi, connection: connection(), home: home), .connected)

            try HarnessConnector.connect(pi, connection: connection(8001), home: home)
            XCTAssertEqual(
                HarnessConnector.status(pi, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(pi, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(pi, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - omp

    private func ompYml(_ home: URL) -> String {
        (try? String(contentsOf: home.appendingPathComponent(".omp/agent/models.yml"),
                     encoding: .utf8)) ?? ""
    }

    func testOmp() throws {
        try withHome { home in
            let omp = AIHarnesses.all.first { $0.id == "omp" }!
            let models = home.appendingPathComponent(".omp/agent/models.yml")

            XCTAssertEqual(
                HarnessConnector.status(omp, connection: connection(), home: home), .notConfigured)

            // Another provider and a following top-level section survive.
            try seed(Data("""
            providers:
              omlx:
                baseUrl: http://127.0.0.1:11434/v1
                api: openai-completions
                auth: none

            shortcuts:
              pi: pi --continue

            """.utf8), models)

            let note = try HarnessConnector.connect(omp, connection: connection(), home: home)
            XCTAssertTrue(note.contains("models.yml"))
            let text = ompYml(home)
            XCTAssertTrue(text.contains("  splash:"))
            XCTAssertTrue(text.contains("    baseUrl: http://127.0.0.1:8000/v1"))
            XCTAssertTrue(text.contains("      type: openai-models-list"))
            XCTAssertTrue(text.contains("      \(model):"))
            XCTAssertTrue(text.contains("        input: [text, image]"))
            XCTAssertTrue(text.contains("        contextWindow: 98304"))
            XCTAssertTrue(text.contains("        maxContextWindow: 98304"))
            // The other provider and the trailing section are intact.
            XCTAssertTrue(text.contains("  omlx:"))
            XCTAssertEqual(text.components(separatedBy: "  omlx:").count - 1, 1)
            XCTAssertEqual(text.components(separatedBy: "shortcuts:").count - 1, 1)
            XCTAssertTrue(text.contains("  pi: pi --continue"))

            XCTAssertEqual(
                HarnessConnector.status(omp, connection: connection(), home: home), .connected)

            // Replacing the block doesn't duplicate or eat the neighbours.
            try HarnessConnector.connect(omp, connection: connection(8001), home: home)
            let text2 = ompYml(home)
            XCTAssertEqual(text2.components(separatedBy: "  splash-8001:").count - 1, 1)
            XCTAssertEqual(text2.components(separatedBy: "shortcuts:").count - 1, 1)
            XCTAssertEqual(
                HarnessConnector.status(omp, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(omp, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(omp, connection: connection(), home: home), .connected)
        }
    }

    func testOmpWithoutProvidersKey() throws {
        try withHome { home in
            let omp = AIHarnesses.all.first { $0.id == "omp" }!
            try seed(Data("shortcuts:\n  pi: pi --continue\n".utf8),
                     home.appendingPathComponent(".omp/agent/models.yml"))
            try HarnessConnector.connect(omp, connection: connection(), home: home)
            let text = ompYml(home)
            XCTAssertTrue(text.contains("providers:"))
            XCTAssertTrue(text.contains("  splash:"))
            XCTAssertTrue(text.contains("shortcuts:"))
            XCTAssertEqual(
                HarnessConnector.status(omp, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - hermes

    private func hermesProfileYaml(_ home: URL, _ profile: String) -> String {
        (try? String(contentsOf: home.appendingPathComponent(
            ".hermes/profiles/\(profile)/config.yaml"), encoding: .utf8)) ?? ""
    }

    func testHermes() throws {
        try withHome { home in
            let hermes = AIHarnesses.all.first { $0.id == "hermes" }!

            XCTAssertEqual(
                HarnessConnector.status(hermes, connection: connection(), home: home), .notConfigured)

            // Pre-create the profile so no subprocess is needed.
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".hermes/profiles/splash"),
                withIntermediateDirectories: true)
            try Data("""
            telemetry:
              enabled: false
            model:
              provider: custom
              base_url: http://127.0.0.1:18000/v1

            """.utf8).write(to: home.appendingPathComponent(
                ".hermes/profiles/splash/config.yaml"))

            // A stale custom profile reports elsewhere first.
            XCTAssertEqual(
                HarnessConnector.status(hermes, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:18000/v1"))

            let note = try HarnessConnector.connect(hermes,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("splash"))
            let text = hermesProfileYaml(home, "splash")
            XCTAssertTrue(text.contains("model:"))
            XCTAssertTrue(text.contains("  default: \(model)"))
            XCTAssertTrue(text.contains("  provider: custom"))
            XCTAssertTrue(text.contains("  base_url: http://127.0.0.1:8000/v1"))
            XCTAssertTrue(text.contains("  api_key: local"))
            XCTAssertTrue(text.contains("  api_mode: chat_completions"))
            XCTAssertTrue(text.contains("  supports_vision: true"))
            XCTAssertTrue(text.contains("  context_length: 98304"))
            XCTAssertTrue(text.contains("  max_tokens: 24576"))
            // The foreign section and the stale value are handled: the
            // section survives, the stale base_url is gone.
            XCTAssertTrue(text.contains("telemetry:"))
            XCTAssertTrue(text.contains("  enabled: false"))
            XCTAssertFalse(text.contains("18000"))

            XCTAssertEqual(
                HarnessConnector.status(hermes, connection: connection(), home: home), .connected)
        }
    }

    func testHermesOtherProfileCustom() throws {
        try withHome { home in
            let hermes = AIHarnesses.all.first { $0.id == "hermes" }!
            // A profile named after another server, configured custom.
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".hermes/profiles/splash-9000"),
                withIntermediateDirectories: true)
            try seed(Data("""
            model:
              provider: custom
              base_url: http://127.0.0.1:9000/v1

            """.utf8), home.appendingPathComponent(
                ".hermes/profiles/splash-9000/config.yaml"))
            XCTAssertEqual(
                HarnessConnector.status(hermes, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:9000/v1"))
        }
    }

    // MARK: - opencode

    func testOpencode() throws {
        try withHome { home in
            let opencode = AIHarnesses.all.first { $0.id == "opencode" }!
            let config = home.appendingPathComponent(".config/opencode/opencode.json")

            XCTAssertEqual(
                HarnessConnector.status(opencode, connection: connection(), home: home),
                .notConfigured)

            // Pre-existing content survives the merge.
            try seed(Data(#"""
            {"$schema": "https://opencode.ai/config.json",
                "provider": {"openai": {"npm": "@ai-sdk/openai"}},
                "agent": {"build": {"temperature": 0}}}
            """#.utf8), config)

            let note = try HarnessConnector.connect(opencode,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("opencode.json"))
            let obj = try readJSON(config)
            let served = "splash/\(model)"
            XCTAssertEqual(obj["model"] as? String, served)
            XCTAssertEqual(obj["small_model"] as? String, served)
            let agents = try XCTUnwrap(obj["agent"] as? [String: Any])
            let build = try XCTUnwrap(agents["build"] as? [String: Any])
            XCTAssertEqual(build["model"] as? String, served)
            XCTAssertEqual(build["temperature"] as? Int, 0)
            let providers = try XCTUnwrap(obj["provider"] as? [String: Any])
            XCTAssertNotNil(providers["openai"])
            let splash = try XCTUnwrap(providers["splash"] as? [String: Any])
            XCTAssertEqual(splash["npm"] as? String, "@ai-sdk/openai-compatible")
            XCTAssertEqual(splash["name"] as? String, "Splash")
            let options = try XCTUnwrap(splash["options"] as? [String: Any])
            XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(options["apiKey"] as? String, "local")
            let models = try XCTUnwrap(splash["models"] as? [String: Any])
            let entry = try XCTUnwrap(models[model] as? [String: Any])
            XCTAssertEqual(entry["reasoning"] as? Bool, true)
            XCTAssertEqual(entry["attachment"] as? Bool, true)
            let limit = try XCTUnwrap(entry["limit"] as? [String: Any])
            XCTAssertEqual(limit["context"] as? Int, 98304)
            XCTAssertEqual(limit["output"] as? Int, 24576)
            XCTAssertEqual(limit["input"] as? Int, 98304 - 24576)
            let variants = try XCTUnwrap(entry["variants"] as? [String: Any])
            XCTAssertEqual((variants["high"] as? [String: String])?["reasoningEffort"],
                           "high")

            XCTAssertEqual(
                HarnessConnector.status(opencode, connection: connection(), home: home), .connected)

            try HarnessConnector.connect(opencode, connection: connection(8001), home: home)
            XCTAssertEqual(
                HarnessConnector.status(opencode, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(opencode, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(opencode, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - copilot

    func testCopilot() throws {
        try withHome { home in
            let copilot = AIHarnesses.all.first { $0.id == "copilot" }!
            let providers = home.appendingPathComponent(".copilot/providers.json")

            XCTAssertEqual(
                HarnessConnector.status(copilot, connection: connection(), home: home), .notConfigured)

            // Pre-existing content survives the merge.
            try seed(Data(#"""
            {"providers": [{"name": "my-ollama", "type": "openai",
                            "baseUrl": "http://127.0.0.1:11434/v1"}],
             "models": [{"id": "qwen3:8b", "provider": "my-ollama"}]}
            """#.utf8), providers)

            let note = try HarnessConnector.connect(copilot,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("providers.json"))
            let obj = try readJSON(providers)
            let ps = try XCTUnwrap(obj["providers"] as? [[String: Any]])
            XCTAssertEqual(ps.count, 2)
            let mine = ps.first { $0["name"] as? String == "splash" }!
            XCTAssertEqual(mine["type"] as? String, "openai")
            XCTAssertEqual(mine["baseUrl"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(mine["apiKey"] as? String, "local")
            let ms = try XCTUnwrap(obj["models"] as? [[String: Any]])
            XCTAssertEqual(ms.count, 2)
            let mineModel = ms.first { $0["provider"] as? String == "splash" }!
            XCTAssertEqual(mineModel["id"] as? String, model)
            XCTAssertEqual(mineModel["maxPromptTokens"] as? Int, 98304 - 24576)
            XCTAssertEqual(mineModel["maxContextWindowTokens"] as? Int, 98304)
            XCTAssertEqual(mineModel["maxOutputTokens"] as? Int, 24576)
            let supports = try XCTUnwrap((mineModel["capabilities"] as? [String: Any])?["supports"] as? [String: Any])
            XCTAssertEqual(supports["vision"] as? Bool, true)
            XCTAssertEqual(supports["toolCalls"] as? Bool, true)

            XCTAssertEqual(
                HarnessConnector.status(copilot, connection: connection(), home: home), .connected)

            // A stale pair is replaced, not duplicated.
            try HarnessConnector.connect(copilot, connection: connection(8001), home: home)
            let obj2 = try readJSON(providers)
            let ps2 = try XCTUnwrap(obj2["providers"] as? [[String: Any]])
            XCTAssertEqual(ps2.filter {
                ($0["name"] as? String)?.hasPrefix("splash") == true
            }.count, 1)
            XCTAssertEqual(
                HarnessConnector.status(copilot, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(copilot, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(copilot, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - droid

    func testDroid() throws {
        try withHome { home in
            let droid = AIHarnesses.all.first { $0.id == "droid" }!
            let settings = home.appendingPathComponent(".factory/settings.json")

            XCTAssertEqual(
                HarnessConnector.status(droid, connection: connection(), home: home), .notConfigured)

            // Other settings and a user's own custom model survive.
            try seed(Data(#"""
            {"compactionTokenLimit": 100000,
             "customModels": [{"model": "other", "displayName": "Mine",
                               "baseUrl": "https://api.example.com/v1",
                               "provider": "openai"}]}
            """#.utf8), settings)

            let note = try HarnessConnector.connect(droid,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("settings.json"))
            let obj = try readJSON(settings)
            XCTAssertEqual(obj["compactionTokenLimit"] as? Int, 100000)
            let models = try XCTUnwrap(obj["customModels"] as? [[String: Any]])
            XCTAssertEqual(models.count, 2)
            let mine = models.first {
                ($0["displayName"] as? String)?.hasPrefix("splash") == true
            }!
            XCTAssertEqual(mine["model"] as? String, model)
            XCTAssertEqual(mine["baseUrl"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(mine["apiKey"] as? String, "local")
            XCTAssertEqual(mine["provider"] as? String, "generic-chat-completion-api")
            XCTAssertEqual(mine["maxContextLimit"] as? Int, 98304)
            XCTAssertEqual(mine["maxOutputTokens"] as? Int, 24576)

            XCTAssertEqual(
                HarnessConnector.status(droid, connection: connection(), home: home), .connected)

            try HarnessConnector.connect(droid, connection: connection(8001), home: home)
            let models2 = try XCTUnwrap(
                (try readJSON(settings))["customModels"] as? [[String: Any]])
            XCTAssertEqual(models2.filter {
                ($0["displayName"] as? String)?.hasPrefix("splash") == true
            }.count, 1)
            XCTAssertEqual(
                HarnessConnector.status(droid, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(droid, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(droid, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - grok

    private func grokToml(_ home: URL) -> String {
        (try? String(contentsOf: home.appendingPathComponent(".grok/config.toml"),
                     encoding: .utf8)) ?? ""
    }

    func testGrok() throws {
        try withHome { home in
            let grok = AIHarnesses.all.first { $0.id == "grok" }!

            XCTAssertEqual(
                HarnessConnector.status(grok, connection: connection(), home: home), .notConfigured)

            // Pre-existing settings survive: the [models] default is
            // replaced, its other keys and the next table are kept.
            try seed(Data("""
            [models]
            default = "grok-build"
            temperature = 1.0

            [mcp_servers.foo]
            command = "foo"

            """.utf8), home.appendingPathComponent(".grok/config.toml"))

            let note = try HarnessConnector.connect(grok,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("config.toml"))
            let text = grokToml(home)
            XCTAssertTrue(text.contains("[model.splash]"))
            XCTAssertTrue(text.contains("model = \"\(model)\""))
            XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8000/v1\""))
            XCTAssertTrue(text.contains("api_key = \"local\""))
            XCTAssertTrue(text.contains("api_backend = \"chat_completions\""))
            XCTAssertTrue(text.contains("context_window = 98304"))
            XCTAssertTrue(text.contains("max_completion_tokens = 24576"))
            XCTAssertTrue(text.contains("default = \"splash\""))
            XCTAssertFalse(text.contains("default = \"grok-build\""))
            XCTAssertTrue(text.contains("temperature = 1.0"))
            XCTAssertTrue(text.contains("[mcp_servers.foo]"))

            XCTAssertEqual(
                HarnessConnector.status(grok, connection: connection(), home: home), .connected)

            try HarnessConnector.connect(grok, connection: connection(8001), home: home)
            let text2 = grokToml(home)
            XCTAssertEqual(text2.components(separatedBy: "[model.splash-8001]").count - 1, 1)
            XCTAssertEqual(text2.components(separatedBy: "default = \"splash-8001\"")
                           .count - 1, 1)
            XCTAssertEqual(
                HarnessConnector.status(grok, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(grok, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(grok, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - kilo

    func testKilo() throws {
        try withHome { home in
            let kilo = AIHarnesses.all.first { $0.id == "kilo" }!
            let config = home.appendingPathComponent(".config/kilo/kilo.jsonc")

            XCTAssertEqual(
                HarnessConnector.status(kilo, connection: connection(), home: home),
                .notConfigured)

            // Pre-existing content survives the merge.
            try seed(Data(#"""
            {
              "$schema": "https://app.kilo.ai/config.json",
              "model": "ollama/qwen3.8:27b-mlx",
              "provider": {
                "ollama": {
                  "models": {
                    "qwen3.8:27b-mlx": {
                      "limit": { "context": 131072, "output": 32768 }
                    }
                  }
                }
              }
            }
            """#.utf8), config)

            let note = try HarnessConnector.connect(kilo,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("kilo"))
            let obj = try readJSON(config)
            XCTAssertEqual(obj["model"] as? String, "splash/\(model)")
            let providers = try XCTUnwrap(obj["provider"] as? [String: Any])
            XCTAssertNotNil(providers["ollama"])
            let splash = try XCTUnwrap(providers["splash"] as? [String: Any])
            let options = try XCTUnwrap(splash["options"] as? [String: Any])
            XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(options["apiKey"] as? String, "local")
            let models = try XCTUnwrap(splash["models"] as? [String: Any])
            XCTAssertEqual((models[model] as? [String: Any])?["name"] as? String, model)

            XCTAssertEqual(
                HarnessConnector.status(kilo, connection: connection(), home: home), .connected)

            try HarnessConnector.connect(kilo, connection: connection(8001), home: home)
            XCTAssertEqual(
                HarnessConnector.status(kilo, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(kilo, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(kilo, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - kimi

    private func kimiToml(_ home: URL) -> String {
        (try? String(contentsOf: home.appendingPathComponent(".kimi/config.toml"),
                     encoding: .utf8)) ?? ""
    }

    func testKimi() throws {
        try withHome { home in
            let kimi = AIHarnesses.all.first { $0.id == "kimi" }!

            XCTAssertEqual(
                HarnessConnector.status(kimi, connection: connection(), home: home), .notConfigured)

            // Pre-existing provider and model survive.
            try seed(Data("""
            default_model = "kimi-for-coding"

            [providers.kimi-for-coding]
            type = "kimi"
            base_url = "https://api.kimi.com/coding/v1"
            api_key = "sk-xxx"

            [models.kimi-for-coding]
            provider = "kimi-for-coding"
            model = "kimi-for-coding"
            max_context_size = 262144

            """.utf8), home.appendingPathComponent(".kimi/config.toml"))

            let note = try HarnessConnector.connect(kimi,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("config.toml"))
            let text = kimiToml(home)
            XCTAssertTrue(text.contains("default_model = \"\(model)\""))
            XCTAssertFalse(text.contains("default_model = \"kimi-for-coding\""))
            XCTAssertTrue(text.contains("[providers.splash]"))
            XCTAssertTrue(text.contains("type = \"openai_legacy\""))
            XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8000/v1\""))
            XCTAssertTrue(text.contains("api_key = \"local\""))
            // The model id carries a dot: its table key is quoted.
            XCTAssertTrue(text.contains("[models.\"\(model)\"]"))
            XCTAssertTrue(text.contains("provider = \"splash\""))
            XCTAssertTrue(text.contains("max_context_size = 98304"))
            XCTAssertTrue(text.contains("capabilities = [\"thinking\", \"image_in\"]"))
            // The other provider and model are intact.
            XCTAssertTrue(text.contains("[providers.kimi-for-coding]"))
            XCTAssertTrue(text.contains("api_key = \"sk-xxx\""))
            XCTAssertEqual(text.components(separatedBy: "[models.kimi-for-coding]")
                           .count - 1, 1)

            XCTAssertEqual(
                HarnessConnector.status(kimi, connection: connection(), home: home), .connected)

            // The old table is replaced, not duplicated.
            try HarnessConnector.connect(kimi, connection: connection(8001), home: home)
            let text2 = kimiToml(home)
            XCTAssertEqual(text2.components(separatedBy: "[providers.splash-8001]")
                           .count - 1, 1)
            XCTAssertEqual(text2.components(separatedBy: "[providers.splash]").count - 1, 0)
            XCTAssertEqual(
                HarnessConnector.status(kimi, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(kimi, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(kimi, connection: connection(), home: home), .connected)
        }
    }

    // MARK: - mastracode

    func testMastracode() throws {
        try withHome { home in
            let mastra = AIHarnesses.all.first { $0.id == "mastracode" }!
            let settings = home.appendingPathComponent(
                "Library/Application Support/mastracode/settings.json")

            XCTAssertEqual(
                HarnessConnector.status(mastra, connection: connection(), home: home),
                .notConfigured)

            // Pre-existing settings survive the merge.
            try seed(Data(#"""
            {"models": {"activeModelPackId": "openai"}, "yolo": true}
            """#.utf8), settings)

            let note = try HarnessConnector.connect(mastra,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("settings.json"))
            let obj = try readJSON(settings)
            XCTAssertEqual(obj["yolo"] as? Bool, true)
            let models = try XCTUnwrap(obj["models"] as? [String: Any])
            XCTAssertEqual(models["activeModelPackId"] as? String, "openai")
            let providers = try XCTUnwrap(obj["customProviders"] as? [[String: Any]])
            XCTAssertEqual(providers.count, 1)
            XCTAssertEqual(providers[0]["name"] as? String, "splash")
            XCTAssertEqual(providers[0]["url"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(providers[0]["apiKey"] as? String, "local")
            XCTAssertEqual(providers[0]["models"] as? [String], [model])

            XCTAssertEqual(
                HarnessConnector.status(mastra, connection: connection(), home: home),
                .connected)

            try HarnessConnector.connect(mastra, connection: connection(8001), home: home)
            let providers2 = try XCTUnwrap(
                (try readJSON(settings))["customProviders"] as? [[String: Any]])
            XCTAssertEqual(providers2.filter {
                ($0["name"] as? String)?.hasPrefix("splash") == true
            }.count, 1)
            XCTAssertEqual(
                HarnessConnector.status(mastra, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(mastra, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(mastra, connection: connection(), home: home),
                .connected)
        }
    }

    // MARK: - qwen

    func testQwen() throws {
        try withHome { home in
            let qwen = AIHarnesses.all.first { $0.id == "qwen" }!
            let settings = home.appendingPathComponent(".qwen/settings.json")

            XCTAssertEqual(
                HarnessConnector.status(qwen, connection: connection(), home: home),
                .notConfigured)

            // The user's own ollama entry and its env key survive.
            try seed(Data(#"""
            {"$version": 4,
             "env": {"OLLAMA_API_KEY": "ollama"},
             "model": {"name": "qwen3.8:27b-mlx"},
             "modelProviders": {"openai": [
                {"baseUrl": "http://127.0.0.1:11434/v1",
                 "envKey": "OLLAMA_API_KEY",
                 "id": "qwen3.8:27b-mlx",
                 "name": "qwen3.8:27b-mlx (Ollama)"}]}}
            """#.utf8), settings)

            let note = try HarnessConnector.connect(qwen,
                                                    connection: connection(), home: home)
            XCTAssertTrue(note.contains("settings.json"))
            let obj = try readJSON(settings)
            XCTAssertEqual(obj["$version"] as? Int, 4)
            let env = try XCTUnwrap(obj["env"] as? [String: Any])
            XCTAssertEqual(env["OLLAMA_API_KEY"] as? String, "ollama")
            XCTAssertEqual(env["SPLASH_API_KEY"] as? String, "local")
            XCTAssertEqual((obj["model"] as? [String: Any])?["name"] as? String, model)
            let providers = try XCTUnwrap(obj["modelProviders"] as? [String: Any])
            let openai = try XCTUnwrap(providers["openai"] as? [[String: Any]])
            XCTAssertEqual(openai.count, 2)
            let mine = openai.first { $0["envKey"] as? String == "SPLASH_API_KEY" }!
            XCTAssertEqual(mine["id"] as? String, model)
            XCTAssertEqual(mine["baseUrl"] as? String, "http://127.0.0.1:8000/v1")
            XCTAssertEqual(openai.first {
                $0["envKey"] as? String == "OLLAMA_API_KEY"
            }?["id"] as? String, "qwen3.8:27b-mlx")

            XCTAssertEqual(
                HarnessConnector.status(qwen, connection: connection(), home: home),
                .connected)

            try HarnessConnector.connect(qwen, connection: connection(8001), home: home)
            let openai2 = try XCTUnwrap(
                ((try readJSON(settings))["modelProviders"] as? [String: Any])?["openai"]
                    as? [[String: Any]])
            XCTAssertEqual(openai2.filter {
                $0["envKey"] as? String == "SPLASH_API_KEY"
            }.count, 1)
            XCTAssertEqual(
                HarnessConnector.status(qwen, connection: connection(), home: home),
                .elsewhere("http://127.0.0.1:8001/v1"))
            try HarnessConnector.connect(qwen, connection: connection(), home: home)
            XCTAssertEqual(
                HarnessConnector.status(qwen, connection: connection(), home: home),
                .connected)
        }
    }

    // MARK: - JSONC stripping

    func testStripJSONComments() {
        let jsonc = """
        { // trailing
          "a": "http://x//y", /* block
             comment */ "b": 1
        }
        """
        let stripped = HarnessConnector.stripJSONComments(jsonc)
        let obj = try! JSONSerialization.jsonObject(with: Data(stripped.utf8))
            as! [String: Any]
        XCTAssertEqual(obj["a"] as? String, "http://x//y")
        XCTAssertEqual(obj["b"] as? Int, 1)
    }
}
