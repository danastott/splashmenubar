import AppKit
import SwiftUI

/// One finished download (or removal problem) worth showing the user.
struct ModelManageResult: Equatable {
    let ok: Bool
    let text: String
}

/// State for the Manage models window: the cache listing, a running
/// download with its streamed output, and the remove actions.
final class ModelManageModel: ObservableObject {
    @Published private(set) var repos: [CacheRepo] = []
    @Published private(set) var scanning = true
    @Published var selectedRepoID: String?
    /// Repo to download, `owner/repo` — or `owner/repo:VARIANT` to fetch
    /// just that GGUF variant (plus the vision projectors) instead of the
    /// whole repo.
    @Published var downloadRepo = ""
    /// Branch, tag or commit to fetch; blank = the repo's default branch.
    @Published var downloadRevision = ""
    /// Repo ids whose version list is open in the view.
    @Published var expanded: Set<String> = []
    @Published private(set) var downloading = false
    @Published private(set) var downloadOutput = ""
    @Published private(set) var downloadFinished: ModelManageResult?
    /// A failed remove (cleared on the next successful action).
    @Published private(set) var removeError: String?

    private var proc: Process?

    /// Whether downloads are possible at all: splash (and its bundled
    /// Python) is on the PATH.
    var downloadCommandAvailable: Bool {
        ModelCache.downloadCommand(repo: "x/y", revision: nil) != nil
    }

    /// Re-reads the cache on a background queue.
    func rescan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let repos = ModelCache.repos()
            DispatchQueue.main.async {
                guard let self else { return }
                self.repos = repos
                self.scanning = false
            }
        }
    }

    /// Starts the download in the background, streaming the downloader's
    /// output into `downloadOutput`.
    func startDownload() {
        let repo = downloadRepo.trimmingCharacters(in: .whitespaces)
        let revision = downloadRevision.trimmingCharacters(in: .whitespaces)
        guard !downloading, !repo.isEmpty,
              let cmd = ModelCache.downloadCommand(repo: repo,
                                                   revision: revision.isEmpty ? nil : revision)
        else { return }
        downloading = true
        downloadOutput = "$ \(cmd.display)\n"
        downloadFinished = nil
        removeError = nil

        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: cmd.python)
        p.arguments = cmd.arguments
        var env = SplashProcess.childEnvironment()
        // huggingface_hub hides its progress bars when stderr isn't a TTY;
        // -1 forces them on so the window can show download progress.
        env["TQDM_POSITION"] = "-1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadOutput += text
                // tqdm rewrites its bar line in place; keep the log bounded.
                if self.downloadOutput.count > 200_000 {
                    self.downloadOutput = String(self.downloadOutput.suffix(100_000))
                }
            }
        }
        p.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.proc = nil
                self.downloading = false
                if finished.terminationStatus == 0 {
                    self.downloadFinished = ModelManageResult(
                        ok: true, text: "Downloaded \(repo) into the model cache.")
                } else {
                    self.downloadFinished = ModelManageResult(
                        ok: false,
                        text: "The download exited with status \(finished.terminationStatus).")
                }
                self.rescan()
            }
        }
        do {
            try p.run()
            proc = p
        } catch {
            proc = nil
            downloading = false
            downloadFinished = ModelManageResult(
                ok: false,
                text: "Couldn't start the download: \(error.localizedDescription)")
        }
    }

    func cancelDownload() {
        guard let p = proc, p.isRunning else { return }
        p.terminate()
    }

    /// Removes one snapshot (and the blobs only it uses) on a background
    /// queue, refreshing the listing after.
    func removeVersion(repo: String, commit: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Int64, Error>
            do {
                result = .success(try ModelCache.removeVersion(
                    repo: repo, commit: commit))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.removeError = nil
                    self.selectedRepoID = repo
                case .failure(let error):
                    self.removeError = error.localizedDescription
                }
                self.rescan()
            }
        }
    }

    /// Removes a whole repo on a background queue, refreshing after.
    func removeRepo(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Int64, Error>
            do {
                result = .success(try ModelCache.removeRepo(id))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.removeError = nil
                    self.selectedRepoID = nil
                case .failure(let error):
                    self.removeError = error.localizedDescription
                }
                self.rescan()
            }
        }
    }
}

/// Window listing the models (and the versions of each) in the Hugging
/// Face cache, with downloads and removals.
struct ModelManageView: View {
    @ObservedObject var model: ModelManageModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model cache")
                .font(.system(size: 13, weight: .semibold))
            Text("Where splash keeps downloaded models (~/.cache/huggingface/hub). A repo can hold several versions — the commits of its default branch it has fetched. Downloading adds; removing frees disk.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.scanning {
                ProgressView().controlSize(.small)
            } else {
                repoList
            }

            Divider()
            downloadSection
            resultLine

            HStack {
                if model.removeError != nil || model.scanning {
                    Spacer()
                } else if model.downloadCommandAvailable {
                    Text("Downloads use splash's bundled Python.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("Install splash to download models.")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                Spacer()
                let title: LocalizedStringKey = model.downloading ? "Working…" : "Close"
                Button(title) { onClose() }
                    .disabled(model.downloading)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 540)
    }

    // MARK: - The listing

    private var repoList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.repos) { repo in
                    repoGroup(repo)
                    Divider()
                }
                if model.repos.isEmpty {
                    Text("The cache is empty — download a model below.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
    }

    private func repoGroup(_ repo: CacheRepo) -> some View {
        let isExpanded = model.expanded.contains(repo.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if isExpanded { model.expanded.remove(repo.id) }
                    else { model.expanded.insert(repo.id) }
                } label: {
                    Image(systemName: isExpanded
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Text(repo.id)
                    .font(.system(size: 12, weight: .medium))
                let versions = Plural.format("versions", repo.versions.count)
                Text("· \(Fmt.bytes(Int(repo.totalSize))) · \(versions)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    confirmRemove(
                        String(localized: "Remove \(repo.id) from the model cache?"),
                        // "removeVersions.one"/"removeVersions.other" keys.
                        informative: Plural.format("removeVersions", repo.versions.count, [Fmt.bytes(Int(repo.totalSize))]),
                        action: { model.removeRepo(repo.id) })
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this model (all versions)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if isExpanded {
                ForEach(repo.versions) { v in
                    versionRow(repo, v)
                }
            }
        }
    }

    private func versionRow(_ repo: CacheRepo, _ v: CacheVersion) -> some View {
        HStack(spacing: 8) {
            Text(v.shortCommit)
                .font(.system(size: 11, design: .monospaced))
            Text(v.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(Fmt.bytes(Int(v.size)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if v.isMainRef {
                Text("current")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.accentColor)
            }
            if v.completeVariants.isEmpty {
                let status: LocalizedStringKey = v.isComplete ? "complete" : "partial"
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(v.isComplete ? .secondary : .orange)
            } else {
                Text("complete: \(v.completeVariants.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                confirmRemove(
                    String(localized: "Remove version \(v.shortCommit) of \(repo.id)?"),
                    informative: String(localized: "Frees about \(Fmt.bytes(Int(v.size))) (plus any cache files only this version uses). Other versions of the model stay. splash can re-download it."),
                    action: { model.removeVersion(repo: repo.id, commit: v.commit) })
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this version")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 3)
    }

    // MARK: - Downloading

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("owner/repo — any Hugging Face model repo",
                          text: $model.downloadRepo)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                TextField("revision — branch, tag or commit (blank = default)",
                          text: $model.downloadRevision)
                    .textFieldStyle(.roundedBorder)
                let title: LocalizedStringKey = model.downloading ? "Downloading…" : "Download"
                Button(title) {
                    model.startDownload()
                }
                .disabled(model.downloading
                          || model.downloadRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.downloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    ScrollViewReader { reader in
                        ScrollView {
                            Text(model.downloadOutput)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(6)
                                .id("log")
                        }
                        .frame(height: 90)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        .onChange(of: model.downloadOutput) { _ in
                            reader.scrollTo("log", anchor: .bottom)
                        }
                    }
                    Button("Cancel") { model.cancelDownload() }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        if let result = model.downloadFinished {
            Text(result.text)
                .font(.system(size: 11))
                .foregroundColor(result.ok ? .green : .red)
                .textSelection(.enabled)
        } else if let error = model.removeError {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(.red)
                .textSelection(.enabled)
        }
    }

    // MARK: - Confirmation

    private func confirmRemove(_ message: String, informative: String,
                               action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}
