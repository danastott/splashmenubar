import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel used for the metrics flyout.
final class MetricsPanel: NSPanel {
    /// Called on Esc; the app decides whether to close (not when pinned).
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = MetricsStore()
    private let proc = SplashProcess()
    private var config = SplashConfig.default
    private var cancellables = Set<AnyCancellable>()

    private var panel: MetricsPanel?
    private var panelVisible = false
    private var panelHosting: NSHostingView<MetricsView>?
    private var panelScrolls = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var settingsWindow: NSWindow?
    private var installWindow: NSWindow?
    private var installModel: InstallModel?
    private var pollTask: Task<Void, Never>?
    private let thermalSensor = ThermalSensor()
    private let systemMonitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = SplashConfig.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Splash's own mark, faint until a model serves (as the Splash app shows it).
            button.image = SplashMark.menuBarImage(serving: false)
            button.image?.accessibilityDescription = "Splash"
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Readers and state callbacks arrive on the main thread.
        proc.onLine = { [weak self] line in
            self?.store.handle(line: line)
        }
        proc.onState = { [weak self] s in
            self?.store.state = s
        }

        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                store.$state, store.$liveTokensPerSecond, store.$requests, store.$endpointAlive
            ),
            Publishers.CombineLatest4(
                store.$startupFraction, store.$readyModel, store.$endpointReady, store.$prefillFraction
            )
        )
            .map { first, startup -> String in
                let (state, live, _, endpointAlive) = first
                let (fraction, readyModel, endpointReady, prefill) = startup
                // Same as store.isStartingUp, from the emitted (new) values:
                // @Published fires before the property is stored.
                let startingUp = readyModel == nil && !endpointReady
                // Speed only while decoding; idle shows the green dot rather
                // than the last request's (stale) speed.
                let tps = live
                // Prompt prefill in progress and nothing decoding: show how far
                // along the prompt is instead of a stale speed.
                let prefillTitle: String? = (live == nil ? prefill : nil)
                    .map { String(format: " ◐ %d%%", Int($0 * 100)) }
                switch state {
                case .running, .starting:
                    if startingUp {
                        // Downloading / loading: show how far along it is.
                        if let fraction { return String(format: " ⏳ %d%%", Int(fraction * 100)) }
                        return " ⏳"
                    }
                    if let prefillTitle { return prefillTitle }
                    if let tps { return String(format: " %.1f t/s", tps) }
                    // Serving and idle.
                    return " ●"
                case .stopped, .crashed:
                    // A server is answering /status even though it is not our
                    // child (started externally or left over): show its activity.
                    if endpointAlive {
                        if let prefillTitle { return prefillTitle }
                        if let tps { return String(format: " %.1f t/s", tps) }
                        return endpointReady ? " ●" : " ⏳"
                    }
                    if case .crashed = state { return " ✕" }
                    return ""
                }
            }
            .removeDuplicates()
            .sink { [weak self] title in
                self?.setStatusTitle(title)
            }
            .store(in: &cancellables)

        // Menu bar mark: solid once a model is serving, faint otherwise.
        Publishers.CombineLatest(store.$endpointReady, store.$endpointAlive)
            .map { ready, alive in ready && alive }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] serving in
                let image = SplashMark.menuBarImage(serving: serving)
                image.accessibilityDescription = "Splash"
                self?.statusItem?.button?.image = image
            }
            .store(in: &cancellables)

        // Tooltip: what splash is doing while it starts up.
        Publishers.CombineLatest3(store.$startupTitle, store.$startupDetail, store.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] title, detail, _ in
                guard let self else { return }
                if self.store.isStartingUp, let title {
                    self.statusItem?.button?.toolTip = [title, detail].compactMap { $0 }.joined(separator: "\n")
                } else {
                    self.statusItem?.button?.toolTip = "Splash"
                }
            }
            .store(in: &cancellables)

        // Keep an open flyout sized to its content (the startup card comes
        // and goes, the crash card appears).
        store.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanelToFit() }
            .store(in: &cancellables)

        startPolling()

        // Requirement: launching the menu bar app starts splash — once the
        // CLI is installed; otherwise offer to install it first.
        startServer()

        // Debug hook: SPLASHMB_AUTOSHOW=panel|settings opens the flyout or
        // settings window shortly after launch.
        if let mode = ProcessInfo.processInfo.environment["SPLASHMB_AUTOSHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                if mode == "settings" { self.openSettings() } else { self.togglePanel() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting the app reaps our child but leaves an externally started
        // server untouched.
        proc.stopChild()
    }

    /// Sets the status item text; a "●" (ready, idle) is drawn green.
    private func setStatusTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: font])
        let ns = title as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "●", options: [], range: search)
            if r.location == NSNotFound { break }
            attributed.addAttributes([
                .foregroundColor: NSColor.systemGreen,
                // The glyph sits high in the menu bar font; shrink and center it.
                .font: NSFont.menuBarFont(ofSize: font.pointSize * 0.75),
                .baselineOffset: font.pointSize * 0.08,
            ], range: r)
            search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        button.attributedTitle = attributed
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        if panelVisible {
            dismissPanel()
        } else {
            showPanel(anchor: button, anchorWindow: win)
        }
    }

    private func showPanel(anchor: NSButton, anchorWindow: NSWindow) {
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 360, height: 640)

        // Measure the unclipped content first.
        let handler: (MenuAction) -> Void = { [weak self] in self?.handleAction($0) }
        let plain = NSHostingView(rootView: MetricsView(store: store, config: config, onAction: handler))
        let fitting = plain.fittingSize
        let maxH = visible.height - 8
        let hosting: NSHostingView<MetricsView>
        if fitting.height > maxH {
            hosting = NSHostingView(rootView: MetricsView(store: store, config: config, maxHeight: maxH, onAction: handler))
        } else {
            hosting = plain
        }
        let size = hosting.fittingSize

        // Place the card just below the menu bar, under the status item,
        // clamped into the screen — never off the top or the sides.
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = anchorFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 6), max(visible.minX + 6, visible.maxX - size.width - 6))
        let y = visible.maxY - size.height

        let p = MetricsPanel(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = store.panelPinned ? .floating : .popUpMenu
        p.onCancel = { [weak self] in self?.dismissPanel() }
        p.isMovable = false
        p.hidesOnDeactivate = false
        // The flyout never activates the app; let hover text (.help) show anyway.
        p.allowsToolTipsWhenApplicationIsInactive = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = hosting

        panel = p
        panelHosting = hosting
        panelScrolls = hosting !== plain
        p.orderFront(nil)
        p.makeKey()
        panelVisible = true
        installMonitors()
    }

    /// Grow or shrink the open flyout to its content, keeping its top edge
    /// under the menu bar.
    private func resizePanelToFit() {
        guard panelVisible, let p = panel, let hosting = panelHosting else { return }
        let maxH = ((p.screen ?? NSScreen.main)?.visibleFrame.height ?? 640) - 8
        if panelScrolls {
            // Already capped at the screen height; nothing to do.
            return
        }
        let size = hosting.fittingSize
        guard abs(size.height - p.frame.height) > 0.5 else { return }
        if size.height > maxH {
            // Now too tall to fit: rebuild with the scrolling layout.
            guard let button = statusItem.button, let win = button.window else { return }
            closePanel()
            showPanel(anchor: button, anchorWindow: win)
            return
        }
        var frame = p.frame
        frame.origin.y = frame.maxY - size.height
        frame.size.height = size.height
        p.setFrame(frame, display: true)
    }

    /// Closes the flyout for a user gesture (click outside, Esc, status item,
    /// a flyout button) unless it is pinned.
    private func dismissPanel() {
        guard !store.panelPinned else { return }
        closePanel()
    }

    private func closePanel() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        panelHosting = nil
        panelVisible = false
    }

    // Dismiss on any click or key outside the panel; the status item button
    // is handled by its own action (toggles the panel).
    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let w = event.window, w == self.statusItem.button?.window { return event }
            if self.panelVisible, let w = event.window, w != self.panel {
                self.dismissPanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panelVisible else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                // A click in the menu bar strip is the status item toggle.
                let mouse = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
                   mouse.y >= screen.frame.maxY - 40 {
                    return
                }
            }
            self.dismissPanel()
        }
    }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        globalMonitor = nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Re-read each pass so a new Settings value applies at once.
                let interval = self?.config.refreshInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                self.store.chipTemperatureC = self.thermalSensor?.celsius()
                self.store.system = self.systemMonitor.sample()
                let port = self.config.port
                if let doc = await StatusClient.fetch(port: port) {
                    self.store.apply(status: doc)
                } else {
                    self.store.markPollFailed()
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ action: MenuAction) {
        switch action {
        case .start:
            dismissPanel()
            startServer()
        case .stop:
            dismissPanel()
            guard confirm("Stop the splash server?",
                          info: "Requests in progress are cancelled and the model is unloaded.",
                          button: "Stop") else { return }
            store.resetForRestart()
            proc.stop()
        case .restart:
            dismissPanel()
            guard confirm("Restart the splash server?",
                          info: "Requests in progress are cancelled and the model is reloaded with the current settings.",
                          button: "Restart") else { return }
            store.resetForRestart()
            proc.restart(with: config)
        case .settings:
            dismissPanel()
            openSettings()
        case .togglePin:
            store.panelPinned.toggle()
            // Pinned, it floats below alerts and dialogs instead of over them.
            panel?.level = store.panelPinned ? .floating : .popUpMenu
        case .quit:
            dismissPanel()
            let info = proc.ownsRunningChild
                ? "The splash server this app started will be stopped."
                : "A splash server started outside the app keeps running."
            guard confirm("Quit Splash Menu Bar?", info: info, button: "Quit") else { return }
            NSApp.terminate(nil)
        }
    }

    /// Asks the user to confirm a disruptive action; true if they agree.
    private func confirm(_ message: String, info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - splash installation

    /// Starts `splash serve`, or asks the user to install `splash` first.
    private func startServer() {
        if SplashInstaller.isSplashInstalled {
            proc.start(config)
        } else {
            promptInstall()
        }
    }

    private func promptInstall() {
        if let w = installWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let brew = SplashInstaller.brewPath

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "splash is not installed"
        if brew != nil {
            alert.informativeText = """
            Splash Menu Bar needs the `splash` command-line tool to run the server.

            Install it yourself with:
                \(SplashInstaller.installCommand)

            or let Splash Menu Bar run that command for you now.
            """
            alert.addButton(withTitle: "Install with Homebrew")
        } else {
            alert.informativeText = """
            Splash Menu Bar needs the `splash` command-line tool to run the server, \
            and Homebrew wasn't found to install it.

            Install Homebrew from https://brew.sh, then run:
                \(SplashInstaller.installCommand)

            Afterwards, press Start in the menu bar flyout.
            """
        }
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let copyButton: NSApplication.ModalResponse = brew != nil ? .alertSecondButtonReturn : .alertFirstButtonReturn

        if let brew, response == .alertFirstButtonReturn {
            runInstall(brew: brew)
        } else if response == copyButton {
            copyInstallCommand()
        }
        // "Not Now" / after copying: stay stopped; Start in the flyout re-checks.
    }

    private func runInstall(brew: String) {
        let model = InstallModel()
        let view = InstallView(model: model) { [weak self] installed in
            guard let self else { return }
            self.closeInstallWindow()
            if installed { self.startServer() }
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Splash Menu Bar — Install splash"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        installModel = model
        installWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.start(brew: brew)
    }

    private func closeInstallWindow() {
        let w = installWindow
        installWindow = nil
        installModel = nil
        w?.close()
    }

    // MARK: - Settings window

    private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            settings: SettingsModel(config: config),
            onSave: { [weak self] new in
                guard let self else { return }
                if new != self.config {
                    // Only splash options restart the server; the refresh
                    // interval is the app's own and applies on the next poll.
                    let serverChanged = new.serveArguments != self.config.serveArguments
                    self.config = new
                    new.save()
                    if serverChanged {
                        self.store.resetForRestart()
                        self.proc.restart(with: new)
                    } else {
                        // Wake the poll loop now instead of after the old interval.
                        self.startPolling()
                    }
                }
                self.closeSettings()
            },
            onDismiss: { [weak self] in
                self?.closeSettings()
            }
        )
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Splash Menu Bar — Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func closeSettings() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    private func reopenPanel() {
        guard let button = statusItem.button, let win = button.window, !panelVisible else { return }
        showPanel(anchor: button, anchorWindow: win)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === installWindow {
            // Closed via the title bar: stop a running install.
            installModel?.cancel()
            installWindow = nil
            installModel = nil
            return
        }
        guard w === settingsWindow else { return }
        settingsWindow = nil
        reopenPanel()
    }
}
