import XCTest
@testable import SplashMenuBar

final class ModelCacheTests: XCTestCase {
    private let fm = FileManager.default
    private var home: URL!

    /// Runs `block` with HF_HUB_CACHE pointed at a fresh cache dir under a
    /// fresh fake home (ModelCache honors the env var first, exactly like
    /// the real app does), restoring the environment afterwards.
    private func withCacheDir(_ block: (URL) throws -> Void) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("splashmenubar-cache-\(UUID().uuidString)")
        let cache = home.appendingPathComponent(".cache/huggingface/hub")
        let previous = ProcessInfo.processInfo.environment["HF_HUB_CACHE"]
        defer {
            try? fm.removeItem(at: home)
            if let previous {
                setenv("HF_HUB_CACHE", previous, 1)
            } else {
                unsetenv("HF_HUB_CACHE")
            }
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        setenv("HF_HUB_CACHE", cache.path, 1)
        try block(cache)
    }

    /// A snapshot folder of `repo`: each file gets its own blob (a real
    /// file in blobs/) that the snapshot reaches through a relative
    /// symlink, as the real cache is laid out. `shared` names let two
    /// snapshots reference the same blob. The folder's mtime is set
    /// explicitly, since that is the newest-first ordering key.
    private func addSnapshot(_ cache: URL, repo: String, commit: String,
                             files: [(path: String, size: Int, shared: String?)],
                             date: Date) throws {
        let repoDir = cache.appendingPathComponent(
            "models--" + repo.replacingOccurrences(of: "/", with: "--"))
        let snap = repoDir.appendingPathComponent("snapshots")
            .appendingPathComponent(commit)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        for f in files {
            let blobName = f.shared ?? blobName(repo: repo, commit: commit,
                                                path: f.path)
            let blob = repoDir.appendingPathComponent("blobs")
                .appendingPathComponent(blobName)
            if !fm.fileExists(atPath: blob.path) {
                try fm.createDirectory(at: blob.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try Data(count: f.size).write(to: blob)
            }
            // Nested variant directories: one component at a time, and the
            // symlink points at the blob by absolute URL (relative
            // destinations are not resolved against the link's directory).
            let comps = f.path.split(separator: "/").map(String.init)
            var dir = snap
            for c in comps.dropLast() {
                dir = dir.appendingPathComponent(c)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: dir.appendingPathComponent(comps.last!),
                                      withDestinationURL: blob)
        }
        try fm.setAttributes([.modificationDate: date],
                             ofItemAtPath: snap.path)
    }

    /// A flat (no-slash) blob name, as the real cache's sha256 names are.
    private func blobName(repo: String, commit: String, path: String) -> String {
        (repo + "-" + commit + "-" + path).replacingOccurrences(of: "/", with: "--")
    }

    private func writeMainRef(_ cache: URL, repo: String, commit: String) throws {
        let ref = cache.appendingPathComponent(
            "models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("refs").appendingPathComponent("main")
        try fm.createDirectory(at: ref.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try commit.write(to: ref, atomically: true, encoding: .utf8)
    }

    private func mainRef(_ cache: URL, repo: String) -> String? {
        let ref = cache.appendingPathComponent(
            "models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("refs").appendingPathComponent("main")
        return (try? String(contentsOf: ref, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Listing

    func testReposListsVersionsNewestFirst() throws {
        try withCacheDir { cache in
            let now = Date()
            try addSnapshot(cache, repo: "owner/repo",
                            commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                            files: [
                                ("UD-Q4_K_XL/model-00001-of-00003.gguf", 10, nil),
                                ("UD-Q4_K_XL/model-00002-of-00003.gguf", 10, nil),
                                ("UD-Q4_K_XL/model-00003-of-00003.gguf", 10, nil),
                                ("shared.txt", 5, "shared"),
                            ],
                            date: now)
            try addSnapshot(cache, repo: "owner/repo",
                            commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                            files: [
                                ("UD-Q4_K_XL/model-00001-of-00003.gguf", 4, nil),
                                ("shared.txt", 5, "shared"),
                            ],
                            date: now.addingTimeInterval(-1000))
            try writeMainRef(cache, repo: "owner/repo",
                             commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            // A complete safetensors repo.
            try addSnapshot(cache, repo: "zeta/model",
                            commit: "cccccccccccccccccccccccccccccccccccccccc",
                            files: [
                                ("config.json", 1, nil),
                                ("model.safetensors.index.json", 1, nil),
                                ("model-00001-of-00002.safetensors", 7, nil),
                                ("model-00002-of-00002.safetensors", 7, nil),
                            ],
                            date: now)
            let index = #"{"weight_map": {"l1": "model-00001-of-00002.safetensors", "l2": "model-00002-of-00002.safetensors"}}"#
            let indexPath = cache
                .appendingPathComponent("models--zeta--model")
                .appendingPathComponent("snapshots")
                .appendingPathComponent(String(repeating: "c", count: 40))
                .appendingPathComponent("model.safetensors.index.json")
            try index.write(to: indexPath, atomically: true, encoding: .utf8)

            let repos = ModelCache.repos(home: home)
            XCTAssertEqual(repos.map(\.id), ["owner/repo", "zeta/model"])

            let repo = repos[0]
            XCTAssertEqual(repo.versions.count, 2)
            // Newest first: the explicitly newer folder leads.
            XCTAssertEqual(repo.versions[0].commit,
                           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            XCTAssertEqual(repo.versions[1].commit,
                           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            XCTAssertTrue(repo.versions[0].isMainRef)
            XCTAssertFalse(repo.versions[1].isMainRef)
            XCTAssertEqual(repo.mainCommit,
                           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            // Complete split variant in the new snapshot only.
            XCTAssertEqual(repo.versions[0].completeVariants, ["UD-Q4_K_XL"])
            XCTAssertTrue(repo.versions[0].isComplete)
            XCTAssertFalse(repo.versions[1].isComplete)
            XCTAssertTrue(repo.versions[1].completeVariants.isEmpty)
            XCTAssertEqual(repo.versions[0].size, 35)
            // Each blob counted once: 30 (parts) + 4 (old part) + 5 (shared).
            XCTAssertEqual(repo.totalSize, 39)

            XCTAssertTrue(repos[1].versions[0].isComplete)
        }
    }

    func testSafetensorsIndexCompleteness() throws {
        try withCacheDir { cache in
            let now = Date()
            try addSnapshot(cache, repo: "own2/sft",
                            commit: "dddddddddddddddddddddddddddddddddddddddd",
                            files: [
                                ("config.json", 1, nil),
                                ("model.safetensors.index.json", 1, nil),
                                ("model-00001-of-00002.safetensors", 7, nil),
                            ],
                            date: now)
            let index = #"{"weight_map": {"l1": "model-00001-of-00002.safetensors", "l2": "model-00002-of-00002.safetensors"}}"#
            let indexPath = cache
                .appendingPathComponent("models--own2--sft")
                .appendingPathComponent("snapshots")
                .appendingPathComponent(String(repeating: "d", count: 40))
                .appendingPathComponent("model.safetensors.index.json")
            try index.write(to: indexPath, atomically: true, encoding: .utf8)

            var repo = ModelCache.repos(home: home).first!
            // One shard short of what the index lists.
            XCTAssertFalse(repo.versions[0].isComplete)

            // The missing shard lands: the version becomes complete.
            try addSnapshot(cache, repo: "own2/sft",
                            commit: "dddddddddddddddddddddddddddddddddddddddd",
                            files: [("model-00002-of-00002.safetensors", 7, nil)],
                            date: now)
            repo = ModelCache.repos(home: home).first!
            XCTAssertTrue(repo.versions[0].isComplete)
        }
    }

    // MARK: - Removing versions

    func testRemoveVersionPrunesBlobsAndRepointsRef() throws {
        try withCacheDir { cache in
            let now = Date()
            try addSnapshot(cache, repo: "owner/repo",
                            commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                            files: [
                                ("UD-Q4_K_XL/model-00001-of-00003.gguf", 10, nil),
                                ("UD-Q4_K_XL/model-00002-of-00003.gguf", 10, nil),
                                ("UD-Q4_K_XL/model-00003-of-00003.gguf", 10, nil),
                                ("shared.txt", 5, "shared"),
                            ],
                            date: now)
            try addSnapshot(cache, repo: "owner/repo",
                            commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                            files: [
                                ("UD-Q4_K_XL/model-00001-of-00003.gguf", 4, nil),
                                ("shared.txt", 5, "shared"),
                            ],
                            date: now.addingTimeInterval(-1000))
            // The OLDER snapshot is what refs/main points at.
            try writeMainRef(cache, repo: "owner/repo",
                             commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

            let repoDir = cache.appendingPathComponent("models--owner--repo")
            let blob = { (name: String) in
                repoDir.appendingPathComponent("blobs").appendingPathComponent(name).path
            }
            let oldPart = blobName(repo: "owner/repo",
                                   commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                                   path: "UD-Q4_K_XL/model-00001-of-00003.gguf")
            XCTAssertTrue(fm.fileExists(atPath: blob(oldPart)))

            // Only its unique blob is freed (4); the shared blob
            // survives, still linked from the remaining version.
            let freed = try ModelCache.removeVersion(
                repo: "owner/repo",
                commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", home: home)
            XCTAssertEqual(freed, 4)
            XCTAssertFalse(fm.fileExists(
                atPath: repoDir.appendingPathComponent(
                    "snapshots/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").path))
            // The unique blob is pruned; the shared one and the rest survive.
            XCTAssertFalse(fm.fileExists(atPath: blob(oldPart)))
            XCTAssertTrue(fm.fileExists(atPath: blob("shared")))
            XCTAssertTrue(fm.fileExists(
                atPath: repoDir.appendingPathComponent(
                    "snapshots/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").path))
            // refs/main now points at the newest remaining snapshot.
            XCTAssertEqual(mainRef(cache, repo: "owner/repo"),
                           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

            // Removing the last version removes the ref entirely.
            _ = try ModelCache.removeVersion(
                repo: "owner/repo",
                commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", home: home)
            XCTAssertNil(mainRef(cache, repo: "owner/repo"))
            // The shared blob is pruned once nothing references it.
            XCTAssertFalse(fm.fileExists(atPath: blob("shared")))
        }
    }

    // MARK: - Removing repos

    func testRemoveRepo() throws {
        try withCacheDir { cache in
            let now = Date()
            try addSnapshot(cache, repo: "owner/repo",
                            commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                            files: [("model.gguf", 12, nil), ("shared.txt", 5, "shared")],
                            date: now)
            try writeMainRef(cache, repo: "owner/repo",
                             commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            let repoDir = cache.appendingPathComponent("models--owner--repo")
            XCTAssertTrue(fm.fileExists(atPath: repoDir.path))

            let freed = try ModelCache.removeRepo("owner/repo", home: home)
            XCTAssertFalse(fm.fileExists(atPath: repoDir.path))
            // The two blobs (17) plus the 40-char ref file.
            XCTAssertEqual(freed, 17 + 40)
            XCTAssertTrue(ModelCache.repos(home: home).isEmpty)
        }
    }

    // MARK: - Download command

    func testDownloadCommand() throws {
        // The interpreter ships with splash; without it there is nothing
        // to assert beyond the nil.
        guard SplashInstaller.pythonPath() != nil else { return }
        let c = try XCTUnwrap(
            ModelCache.downloadCommand(repo: "owner/repo", revision: nil))
        XCTAssertEqual(c.arguments.count, 3)
        XCTAssertEqual(c.arguments[0], "-c")
        XCTAssertEqual(c.arguments[2], "owner/repo")
        XCTAssertTrue(c.display.contains("owner/repo"))
        XCTAssertTrue(fm.fileExists(atPath: c.python))

        let r = try XCTUnwrap(
            ModelCache.downloadCommand(repo: "owner/repo", revision: "abc123"))
        XCTAssertEqual(r.arguments.count, 4)
        XCTAssertEqual(r.arguments[3], "abc123")
        XCTAssertTrue(r.display.contains("abc123"))

        // A ":VARIANT" suffix scopes the download: the id handed to
        // snapshot_download is the bare repo (huggingface_hub rejects the
        // suffix), the variant only feeds allow_patterns.
        let v = try XCTUnwrap(ModelCache.downloadCommand(
            repo: "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M", revision: nil))
        XCTAssertEqual(v.arguments.count, 4)
        XCTAssertEqual(v.arguments[2], "unsloth/Inkling-2-Mini-GGUF")
        XCTAssertEqual(v.arguments[3],
                       "*-UD-Q4_K_M.gguf,*-UD-Q4_K_M-*-of-*.gguf," +
                       "UD-Q4_K_M/*.gguf,mmproj-*.gguf")
        XCTAssertTrue(v.display.contains("unsloth/Inkling-2-Mini-GGUF"))
        XCTAssertTrue(v.display.contains("UD-Q4_K_M"))
        XCTAssertFalse(v.display.contains("unsloth/Inkling-2-Mini-GGUF:"))

        // Variant and revision together: revision stays argv[2], the
        // patterns follow as argv[3].
        let vr = try XCTUnwrap(ModelCache.downloadCommand(
            repo: "owner/repo:Q4_K_M", revision: "abc123"))
        XCTAssertEqual(vr.arguments.count, 5)
        XCTAssertEqual(vr.arguments[2], "owner/repo")
        XCTAssertEqual(vr.arguments[3], "abc123")
        XCTAssertEqual(vr.arguments[4],
                       "*-Q4_K_M.gguf,*-Q4_K_M-*-of-*.gguf,Q4_K_M/*.gguf," +
                       "mmproj-*.gguf")
    }
}
