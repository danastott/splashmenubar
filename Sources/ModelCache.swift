import Foundation

/// One commit (snapshot) of a cached repo.
struct CacheVersion: Identifiable, Hashable {
    let commit: String
    /// Folder modification date (newest-first ordering key).
    let date: Date
    /// Bytes its files reference (blobs shared between versions are
    /// counted in each).
    let size: Int64
    /// GGUF variants complete in this snapshot (every part of a split file
    /// present), sorted.
    let completeVariants: [String]
    /// Whole-repo completeness: for GGUF repos, any complete variant; for
    /// safetensors repos, config.json plus every shard the index lists.
    let isComplete: Bool
    /// `refs/main` points at this commit — what a plain download or
    /// unpinned start resolves.
    let isMainRef: Bool

    var id: String { commit }
    var shortCommit: String { String(commit.prefix(12)) }
}

/// One cached repo with all of its versions, newest first.
struct CacheRepo: Identifiable, Hashable {
    let id: String
    let dir: URL
    let versions: [CacheVersion]
    /// Bytes of the repo's blobs/ directory (each blob counted once).
    let totalSize: Int64

    var mainCommit: String? {
        versions.first { $0.isMainRef }?.commit
    }
}

/// Listing, downloading and removing the models and model versions in the
/// Hugging Face cache — the place `splash serve` reads them from.
enum ModelCache {

    /// The cache root for `home`: `HF_HUB_CACHE`, else `HF_HOME/hub`, else
    /// `home/.cache/huggingface/hub` (the same lookup as SplashModels).
    static func cacheRoot(home: URL? = nil) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["HF_HUB_CACHE"], !v.isEmpty {
            return URL(fileURLWithPath: v)
        }
        if let v = env["HF_HOME"], !v.isEmpty {
            return URL(fileURLWithPath: v).appendingPathComponent("hub")
        }
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Every `models--*` repo under the cache root, sorted by id.
    static func repos(home: URL? = nil) -> [CacheRepo] {
        let root = cacheRoot(home: home)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var out: [CacheRepo] = []
        for name in names where name.hasPrefix("models--") {
            let dir = root.appendingPathComponent(name)
            let id = String(name.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")
            let refURL = dir.appendingPathComponent("refs")
                .appendingPathComponent("main")
            let mainCommit = (try? String(contentsOf: refURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var versions: [CacheVersion] = []
            let snapDir = dir.appendingPathComponent("snapshots")
            guard let commits = try? fm.contentsOfDirectory(atPath: snapDir.path)
            else { continue }
            for commit in commits {
                let snapshot = snapDir.appendingPathComponent(commit)
                let files = SplashModels.files(in: snapshot)
                let size = files.reduce(Int64(0)) { $0 + $1.size }
                let date = (try? snapshot.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                versions.append(CacheVersion(
                    commit: commit,
                    date: date,
                    size: size,
                    completeVariants: completeGGUFVariants(files),
                    isComplete: isSnapshotComplete(files, snapshot: snapshot),
                    isMainRef: commit == mainCommit))
            }
            versions.sort { $0.date > $1.date }
            out.append(CacheRepo(id: id, dir: dir, versions: versions,
                                 totalSize: directorySize(dir.appendingPathComponent("blobs"))))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// The GGUF variants whose files are all in `files`, sorted by display
    /// name (a split file counts only when every part is present).
    static func completeGGUFVariants(_ files: [(path: String, size: Int64)]) -> [String] {
        var byVariant: [String: [String]] = [:]   // lowercased → paths
        var display: [String: String] = [:]
        for f in files where f.path.lowercased().hasSuffix(".gguf") {
            guard let v = SplashModels.ggufVariant(f.path) else { continue }
            let key = v.lowercased()
            byVariant[key, default: []].append(f.path)
            display[key] = display[key] ?? v
        }
        return byVariant.keys.filter { SplashModels.splitComplete(byVariant[$0]!) }
            .sorted { display[$0]! < display[$1]! }
            .map { display[$0]! }
    }

    /// Whole-repo completeness of one snapshot: a GGUF repo is complete
    /// when any variant's files are all there; a safetensors repo when
    /// config.json and every shard its index lists are.
    static func isSnapshotComplete(_ files: [(path: String, size: Int64)],
                                   snapshot: URL) -> Bool {
        let gguf = files.filter { $0.path.lowercased().hasSuffix(".gguf") }
        if !gguf.isEmpty {
            return !completeGGUFVariants(gguf).isEmpty
        }
        let names = Set(files.map(\.path))
        let weights = files.filter { $0.path.hasSuffix(".safetensors") }
        let shardsComplete = SplashModels.indexShards(snapshot)
            .map { names.isSuperset(of: $0) } ?? true
        return names.contains("config.json") && !weights.isEmpty && shardsComplete
    }

    /// `models--owner--repo` for `id`, found case-insensitively, or nil.
    static func repoDir(_ id: String, home: URL? = nil) -> URL? {
        let want = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let root = cacheRoot(home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              let hit = names.first(where: { $0.caseInsensitiveCompare(want) == .orderedSame })
        else { return nil }
        return root.appendingPathComponent(hit)
    }

    /// Removes one snapshot: deletes `snapshots/<commit>`, prunes the blobs
    /// no remaining snapshot references, and re-points `refs/main` at the
    /// newest remaining snapshot (removing the ref when none remain).
    /// Returns the bytes freed.
    @discardableResult
    static func removeVersion(repo: String, commit: String,
                              home: URL? = nil) throws -> Int64 {
        guard let dir = repoDir(repo, home: home) else {
            throw NSError(domain: "ModelCache", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No cached model \(repo)"])
        }
        let fm = FileManager.default
        let snapDir = dir.appendingPathComponent("snapshots")
        let snapshot = snapDir.appendingPathComponent(commit)
        guard fm.fileExists(atPath: snapshot.path) else {
            throw NSError(domain: "ModelCache", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "No version \(commit) of \(repo) in the cache"])
        }
        try fm.removeItem(at: snapshot)
        // Only blobs that are pruned below are actually freed; the
        // snapshot held symlinks, and blobs shared with remaining
        // versions survive.
        var freed: Int64 = 0

        // Prune blobs no remaining snapshot links to.
        var referenced = Set<String>()
        if let commits = try? fm.contentsOfDirectory(atPath: snapDir.path) {
            for c in commits where c != commit {
                for f in SplashModels.files(
                    in: snapDir.appendingPathComponent(c)) {
                    let resolved = snapDir.appendingPathComponent(c)
                        .appendingPathComponent(f.path)
                        .resolvingSymlinksInPath()
                    referenced.insert(resolved.standardizedFileURL.path)
                }
            }
        }
        let blobDir = dir.appendingPathComponent("blobs")
        if let blobs = try? fm.contentsOfDirectory(atPath: blobDir.path) {
            for b in blobs {
                let path = blobDir.appendingPathComponent(b)
                let resolved = path.resolvingSymlinksInPath()
                guard let attrs = try? fm.attributesOfItem(atPath: resolved.path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular,
                      !referenced.contains(resolved.standardizedFileURL.path)
                else { continue }
                if let size = (attrs[.size] as? NSNumber)?.int64Value {
                    freed += size
                }
                try fm.removeItem(at: path)
            }
        }

        // Keep refs/main pointing at a commit that is still on disk.
        let ref = dir.appendingPathComponent("refs").appendingPathComponent("main")
        let current = (try? String(contentsOf: ref, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current == commit {
            let remaining = ((try? fm.contentsOfDirectory(
                atPath: snapDir.path)) ?? [])
                .map { snapDir.appendingPathComponent($0) }
            if let newest = remaining.max(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }) {
                try newest.lastPathComponent.write(
                    to: ref, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(at: ref)
            }
        }
        return freed
    }

    /// Removes the whole repo directory. Returns the bytes freed.
    @discardableResult
    static func removeRepo(_ id: String, home: URL? = nil) throws -> Int64 {
        guard let dir = repoDir(id, home: home) else {
            throw NSError(domain: "ModelCache", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No cached model \(id)"])
        }
        let freed = directorySize(dir)
        try FileManager.default.removeItem(at: dir)
        return freed
    }

    /// The download command for `repo` (a full Hugging Face repo;
    /// `revision` nil = its default branch), run with splash's bundled
    /// Python and huggingface_hub. nil when splash (and with it the
    /// interpreter) isn't installed. `display` is the human line the UI
    /// shows.
    static func downloadCommand(repo: String, revision: String?)
        -> (python: String, arguments: [String], display: String)? {
        guard let python = SplashInstaller.pythonPath() else { return nil }
        let script = """
            import sys
            from huggingface_hub import snapshot_download
            repo = sys.argv[1]
            revision = sys.argv[2] if len(sys.argv) > 2 else None
            snapshot_download(repo, revision=revision)
            """
        var arguments = ["-c", script, repo]
        var display = "snapshot_download \(repo)"
        if let revision, !revision.isEmpty {
            arguments.append(revision)
            display += " @ \(revision)"
        }
        return (python, arguments, display)
    }

    /// Total size of the regular files under `url` (recursively), 0 when
    /// missing. Symlinks are followed, but each resolved file is counted
    /// once, so snapshot links to blobs don't double the blobs.
    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        var seen = Set<String>()
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil) else { return 0 }
        for case let fileURL as URL in e {
            let resolved = fileURL.resolvingSymlinksInPath()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  seen.insert(resolved.path).inserted,
                  let size = (attrs[.size] as? NSNumber)?.int64Value
            else { continue }
            total += size
        }
        return total
    }
}
