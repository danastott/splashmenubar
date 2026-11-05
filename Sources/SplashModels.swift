import Foundation

/// A model splash can serve, as given to `--model`.
struct KnownModel: Hashable, Identifiable {
    /// `OWNER/REPO[:VARIANT]`.
    let id: String
    /// Short menu label, e.g. "Qwen3.8-27B · GGUF UD-Q4_K_M".
    let label: String
    /// Smallest Mac memory in GB the variant is meant for (splash's
    /// suggested-models.tsv), if known.
    var minMemoryGB: Int? = nil
    /// Download size in GB: the model, its draft, and its vision projector.
    var downloadGB: Int? = nil
    /// Few words for choosing among the models; shared by a model's variants.
    var about: String? = nil
}

/// The supported model families from splash's README, plus what's already in
/// the Hugging Face cache, which is where splash downloads models.
enum SplashModels {
    /// The models to offer, best first. Read from `suggested-models.tsv`
    /// shipped with the installed splash (splash's own desktop app does the
    /// same), so the list tracks splash's releases; the hardcoded table
    /// below is the fallback when splash isn't installed or the file is
    /// missing.
    static var catalog: [KnownModel] {
        tsvCatalog ?? fallbackCatalog
    }

    /// Parsed TSV, read once (nil if the file can't be read or is empty).
    private static let tsvCatalog: [KnownModel]? = loadTsvCatalog()

    /// One recommended GGUF / MLX build per supported family
    /// (https://github.com/incoai/splash#models), as of splash 1.5.
    static let fallbackCatalog: [KnownModel] = [
        .init(id: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", label: "Qwen3.8 27B · GGUF UD-Q4_K_M"),
        .init(id: "mlx-community/Qwen3.8-27B-4bit", label: "Qwen3.8 27B · MLX 4-bit"),
        .init(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M", label: "Qwen3.6 35B-A3B · GGUF UD-Q4_K_M"),
        .init(id: "mlx-community/Qwen3.6-35B-A3B-4bit", label: "Qwen3.6 35B-A3B · MLX 4-bit"),
        .init(id: "unsloth/Ornith-1.5-122B-GGUF:UD-Q4_K_XL", label: "Ornith 1.5 122B · GGUF UD-Q4_K_XL"),
        .init(id: "ornith-ai/Ornith-1.5-122B-MLX-4bit", label: "Ornith 1.5 122B · MLX 4-bit"),
        .init(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0", label: "Qwen3.8 Flash-Next · GGUF Q2_0"),
        .init(id: "unsloth/flint-GGUF:UD-Q4_K_XL", label: "Flint · GGUF UD-Q4_K_XL"),
        .init(id: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0", label: "Ternary Bonsai 2 27B · GGUF PQ2_0"),
    ]

    private static func loadTsvCatalog() -> [KnownModel]? {
        guard let url = suggestedModelsURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let models = parseSuggestedModels(text)
        return models.isEmpty ? nil : models
    }

    /// `suggested-models.tsv` ships inside the splash install, next to its
    /// launcher (`<install>/install/suggested-models.tsv`); nil when splash
    /// isn't on the PATH or the file is missing (e.g. a pip install).
    static func suggestedModelsURL() -> URL? {
        guard let splash = SplashInstaller.locate("splash") else { return nil }
        let fm = FileManager.default
        let raw = URL(fileURLWithPath: splash)
        let resolved = raw.resolvingSymlinksInPath()
        var candidates: [URL] = []
        // Homebrew: <root>/bin/splash → <root>/opt/splash/libexec/install/.
        let rawRoot = raw.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(rawRoot.appendingPathComponent(
            "opt/splash/libexec/install/suggested-models.tsv"))
        // <prefix>/bin/splash → <prefix>/libexec/install/: a Homebrew Cellar
        // version dir, or any prefix with bin/ and libexec/ as siblings.
        let prefix = resolved.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(prefix.appendingPathComponent(
            "libexec/install/suggested-models.tsv"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Parses `suggested-models.tsv` lines:
    /// `MODEL<TAB>NAME<TAB>MEMORY<TAB>SIZE<TAB>ABOUT`, where MEMORY is the
    /// smallest Mac RAM in GB the variant is meant for and SIZE the download
    /// in whole GB. `#` comment lines and rows missing any of the five
    /// fields are skipped.
    static func parseSuggestedModels(_ text: String) -> [KnownModel] {
        var out: [KnownModel] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("#") else { continue }
            let f = s.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 5, !f[0].isEmpty, !f[1].isEmpty else { continue }
            let (repo, variant) = parse(f[0])
            let label: String
            if let v = variant {
                label = "\(f[1]) · GGUF \(v)"
            } else if repo.lowercased().contains("mlx") {
                label = "\(f[1]) · MLX" + (f[0].lowercased().contains("4bit") ? " 4-bit" : "")
            } else {
                label = f[1]
            }
            out.append(.init(id: f[0], label: label,
                             minMemoryGB: Int(f[2]), downloadGB: Int(f[3]), about: f[4]))
        }
        return out
    }

    /// The Hugging Face hub cache: `HF_HUB_CACHE`, else `HF_HOME/hub`, else
    /// `~/.cache/huggingface/hub` (same lookup as splash and `hf`).
    static var cacheRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["HF_HUB_CACHE"], !v.isEmpty { return URL(fileURLWithPath: v) }
        if let v = env["HF_HOME"], !v.isEmpty {
            return URL(fileURLWithPath: v).appendingPathComponent("hub")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// Splits `OWNER/REPO[:VARIANT]`.
    static func parse(_ id: String) -> (repo: String, variant: String?) {
        let t = id.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(of: ":") else { return (t, nil) }
        let variant = String(t[t.index(after: colon)...])
        return (String(t[..<colon]), variant.isEmpty ? nil : variant)
    }

    /// Scans the cache once: on-disk size of each downloaded model id, plus
    /// any other GGUF variants of the catalog's repos found there.
    static func scan() -> (sizes: [String: Int64], extras: [KnownModel]) {
        var sizes: [String: Int64] = [:]
        for m in catalog {
            if let s = downloadedSize(m.id) { sizes[m.id] = s }
        }
        var extras: [KnownModel] = []
        let ggufRepos = Set(catalog.compactMap { m -> String? in
            let p = parse(m.id)
            return p.variant == nil ? nil : p.repo
        })
        let known = Set(catalog.map { $0.id.lowercased() })
        for repo in ggufRepos.sorted() {
            guard let snapshot = snapshotDirs(repo).first else { continue }
            var variants = Set<String>()
            for f in files(in: snapshot) where f.path.lowercased().hasSuffix(".gguf") {
                if let v = ggufVariant(f.path) { variants.insert(v) }
            }
            for v in variants.sorted() {
                let id = "\(repo):\(v)"
                guard !known.contains(id.lowercased()), let s = downloadedSize(id) else { continue }
                let family = catalog.first { parse($0.id).repo == repo }
                let name = family?.label.components(separatedBy: " · ").first ?? repo
                extras.append(.init(id: id, label: "\(name) · GGUF \(v)", about: family?.about))
                sizes[id] = s
            }
        }
        return (sizes, extras)
    }

    /// The folder in the Hugging Face cache where `id`'s files live — the
    /// repo's newest snapshot (files appear in it as the download goes) — or
    /// nil when the repo isn't in the cache at all.
    static func storageURL(for id: String) -> URL? {
        let (repo, _) = parse(id)
        return snapshotDirs(repo).first
    }

    /// Bytes on disk if `id` is fully in the cache, else nil. A GGUF needs
    /// every file of its variant (all parts of a split file); an MLX or other
    /// safetensors repo needs config.json and every shard its index lists.
    static func downloadedSize(_ id: String) -> Int64? {
        let (repo, variant) = parse(id)
        for snapshot in snapshotDirs(repo) {
            let all = files(in: snapshot)
            if let variant {
                let parts = all.filter {
                    $0.path.lowercased().hasSuffix(".gguf")
                        && ggufVariant($0.path)?.lowercased() == variant.lowercased()
                }
                guard !parts.isEmpty, splitComplete(parts.map(\.path)) else { continue }
                return parts.reduce(0) { $0 + $1.size }
            } else {
                let names = Set(all.map(\.path))
                guard names.contains("config.json") else { continue }
                let weights = all.filter { $0.path.hasSuffix(".safetensors") }
                guard !weights.isEmpty else { continue }
                if let needed = indexShards(snapshot), !needed.isSubset(of: names) { continue }
                return weights.reduce(0) { $0 + $1.size }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func repoDir(_ repo: String) -> URL? {
        let want = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let root = cacheRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              let hit = names.first(where: { $0.caseInsensitiveCompare(want) == .orderedSame })
        else { return nil }
        return root.appendingPathComponent(hit)
    }

    /// Snapshot folders, newest first.
    private static func snapshotDirs(_ repo: String) -> [URL] {
        guard let dir = repoDir(repo)?.appendingPathComponent("snapshots"),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Files in a snapshot whose symlinked blob actually exists, with paths
    /// relative to the snapshot and the blob's size.
    private static func files(in snapshot: URL) -> [(path: String, size: Int64)] {
        guard let e = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, Int64)] = []
        let base = snapshot.standardizedFileURL.path + "/"
        for case let url as URL in e {
            let resolved = url.resolvingSymlinksInPath()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0
            else { continue }
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            out.append((rel, size))
        }
        return out
    }

    /// The quant tag of a GGUF path: its folder for split files kept in one
    /// (unsloth's `UD-Q4_K_XL/…-00001-of-00003.gguf`), else the trailing tag
    /// of the file name (`Qwen3.8-27B-UD-Q4_K_M.gguf` → `UD-Q4_K_M`).
    /// Vision projectors (mmproj) have none.
    static func ggufVariant(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last, !file.lowercased().hasPrefix("mmproj") else { return nil }
        if parts.count > 1 { return parts[parts.count - 2] }
        var stem = String(file.dropLast(".gguf".count))
        if let r = stem.range(of: #"-\d{5}-of-\d{5}$"#, options: .regularExpression) {
            stem.removeSubrange(r)
        }
        let pattern = #"(UD-)?(I?Q\d[A-Za-z0-9_]*|PQ\d_\d|TQ\d_\d|BF16|F16|F32|MXFP4[A-Za-z0-9_]*|NVFP4[A-Za-z0-9_]*)$"#
        guard let r = stem.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(stem[r])
    }

    /// True unless the paths are parts of a split GGUF with some missing.
    static func splitComplete(_ paths: [String]) -> Bool {
        var total: Int?
        var seen = Set<Int>()
        for p in paths {
            guard let r = p.range(of: #"-(\d{5})-of-(\d{5})\.gguf$"#, options: .regularExpression)
            else { continue }
            let nums = p[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 2 else { continue }
            seen.insert(nums[0])
            total = nums[1]
        }
        guard let total else { return true }
        return seen.count == total
    }

    /// Shard names from model.safetensors.index.json, if there is one.
    private static func indexShards(_ snapshot: URL) -> Set<String>? {
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: index),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = obj["weight_map"] as? [String: String]
        else { return nil }
        return Set(map.values)
    }
}
