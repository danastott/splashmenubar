import AppKit
import SwiftUI
import Combine
import UserNotifications
import ServiceManagement

/// Borderless, non-activating panel used for the metrics flyout.
final class MetricsPanel: NSPanel {
    /// Called on Esc; the app decides whether to close (not when pinned).
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The status item's text and how its "●" is colored: yellow while splash is
/// starting, green once it runs — the same states and colors as the flyout's
/// status dot.
private struct MenuBarStatus: Equatable {
    let title: String
    let startingUp: Bool
    init(_ title: String, startingUp: Bool = false) {
        self.title = title
        self.startingUp = startingUp
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI's @NSApplicationDelegateAdaptor keeps this object out of
    /// NSApp.delegate (a private proxy stands in for it), so the scene's
    /// views reach the delegate through this reference instead.
    static weak var shared: AppDelegate?

    override init() {
        super.init()
        Self.shared = self
        // Load the saved settings before anything else (not in
        // applicationDidFinishLaunching): the Settings scene's view — and
        // with it the settings form — can be built while the scene installs
        // its menu, before that runs. A form built from the default config
        // would show defaults instead of the saved values, and a Save would
        // write the defaults back over the file.
        let loaded = SplashConfig.load()
        config = loaded.config
        configLoadWarning = loaded.warning
    }

    private var statusItem: NSStatusItem!
    private let store = MetricsStore()

    private let proc = SplashProcess()
    /// The default stands in only until init loads the saved config.
    private var config = SplashConfig.default
    /// Why the defaults are in use (the saved file couldn't be read);
    /// applicationDidFinishLaunching shows it.
    private var configLoadWarning: String?
    private var cancellables = Set<AnyCancellable>()

    private var panel: MetricsPanel?
    private var panelVisible = false
    /// Set before closing the panel so windowWillClose doesn't reopen it.
    private var deferPanelReopen = false
    private var panelHosting: NSHostingView<MetricsView>?
    private var panelScrolls = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    // The settings form state lives here (not in the Settings scene's
    // view) so it survives the window closing and reopening, and other
    // app code can reach it (the cache rescan after Manage models
    // closes). Lazily created on first access — ⌘, reaches the scene
    // without going through openSettings().
    private var _settingsModel: SettingsModel?
    var settingsModel: SettingsModel {
        if let m = _settingsModel { return m }
        let m = SettingsModel(config: config)
        _settingsModel = m
        return m
    }
    private var _harnesses: HarnessModel?
    var harnesses: HarnessModel {
        if let m = _harnesses { return m }
        // Auto Connect needs what the server reports about itself — the
        // served model's name, its context window and what it accepts —
        // as the last /status said (a stopped server keeps its last one).
        let m = HarnessModel(connectionProvider: { [weak self] in
            guard let self,
                  let model = self.store.modelFromStatus, !model.isEmpty,
                  let context = self.store.maxContextTokens, context > 0
            else { return nil }
            return HarnessConnection(port: self.config.port,
                                      model: model,
                                      context: context,
                                      modalities: self.store.inputModalities)
        })
        _harnesses = m
        return m
    }
    private var modelManageWindow: NSWindow?
    /// The window's state object, kept so a title-bar close can stop a
    /// running download (the Close button is disabled while one runs, but
    /// the red button isn't).
    private var modelManageModel: ModelManageModel?
    private var installWindow: NSWindow?
    private var installModel: InstallModel?
    private var pollTask: Task<Void, Never>?
    /// Scans for a splash started outside the app while none is connected.
    private var discoveryTask: Task<Void, Never>?
    /// Seconds between scans for an externally started splash.
    private static let discoveryInterval: TimeInterval = 5
    private let thermalSensor = ThermalSensor()
    private let systemMonitor = SystemMonitor()
    /// Set when the quit dialog's "leave the splash server running"
    /// checkbox was on: the app's own server then survives the quit
    /// (reparented to launchd; the next start adopts it on the configured
    /// port).
    private var leaveServerRunningOnQuit = false
    /// Set before a programmatic terminate (the relaunch after an update or
    /// a language change) so the quit dialog is skipped.
    private var forceTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No settings file yet: this is the app's first launch.
        let firstLaunch = !FileManager.default.fileExists(atPath: SplashConfig.configURL.path)
        store.gaugeColors = config.gaugeColors
        if let warning = configLoadWarning {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn't read saved settings")
            alert.informativeText = warning
            alert.addButton(withTitle: String(localized: "OK"))
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }

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
            guard let self else { return }
            // A dead server is worth a notification — unless it is being
            // auto-restarted, where the flyout and menu bar already say so.
            if case .crashed(let info) = s, !self.proc.autoRestartScheduled {
                self.postCrashNotificationIfNeeded(info)
            }
            self.store.state = s
        }

        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                store.$state, store.$liveTokensPerSecond, store.$requests, store.$endpointAlive
            ),
            Publishers.CombineLatest4(
                store.$startupFraction, store.$readyModel, store.$endpointReady, store.$prefillFraction
            )
        )
            .map { first, startup -> MenuBarStatus in
                let (state, live, _, endpointAlive) = first
                let (fraction, readyModel, endpointReady, prefill) = startup
                // Same as store.isStartingStatus, from the emitted (new)
                // values: @Published fires before the property is stored.
                let startingUp = state == .starting || (readyModel == nil && !endpointReady)
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
                        if let fraction {
                            return MenuBarStatus(String(format: " ● %d%%", Int(fraction * 100)), startingUp: true)
                        }
                        return MenuBarStatus(" ●", startingUp: true)
                    }
                    if let prefillTitle { return MenuBarStatus(prefillTitle) }
                    if let tps { return MenuBarStatus(String(format: " %.1f t/s", tps)) }
                    // Serving and idle.
                    return MenuBarStatus(" ●")
                case .stopped, .crashed:
                    // A server is answering /status even though it is not our
                    // child (started externally or left over): show its activity.
                    if endpointAlive {
                        if let prefillTitle { return MenuBarStatus(prefillTitle) }
                        if let tps { return MenuBarStatus(String(format: " %.1f t/s", tps)) }
                        // The flyout calls any running server green, ready or not.
                        return MenuBarStatus(" ●")
                    }
                    if case .crashed = state { return MenuBarStatus(" ✕") }
                    return MenuBarStatus("")
                }
            }
            .removeDuplicates()
            .sink { [weak self] status in
                self?.setStatusTitle(status.title, startingUp: status.startingUp)
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

        // Tooltip: what splash is doing, plus the version of the splash
        // server (when one is serving).
        Publishers.CombineLatest4(
            store.$startupTitle, store.$startupDetail, store.$state, store.$serverVersion
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] title, detail, _, version in
                guard let self else { return }
                var base: [String]
                if self.store.isStartingUp, let title {
                    base = [title, detail].compactMap { $0 }
                } else {
                    base = ["Splash"]
                }
                if let version { base.append("splash \(version)") }
                self.statusItem?.button?.toolTip = base.joined(separator: "\n")
            }
            .store(in: &cancellables)

        // Keep an open flyout sized to its content (the startup card comes
        // and goes, the crash card appears).
        store.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanelToFit() }
            .store(in: &cancellables)

        // A server start is a natural moment to look for a splash release
        // that appeared while the app was out.
        store.$state
            .removeDuplicates()
            .filter { $0 == .starting }
            .sink { [weak self] _ in self?.checkSplashUpdate() }
            .store(in: &cancellables)

        startPolling()
        setupNotifications()
        watchNotificationTriggers()
        checkSplashUpdate()
        checkAppUpdate()

        // Start splash only if the user asked for it in Settings (off by
        // default). First, though, look for a splash that's already running
        // — on any port — and connect to it; with none, start ours (if asked
        // to) or show the tip to pick a model. A missing CLI is offered first.
        if !SplashInstaller.isSplashInstalled {
            promptInstall(thenStart: config.startServerOnLaunch)
        } else {
            connectOrSetUp(openFlyout: firstLaunch, startIfNone: config.startServerOnLaunch)
        }
        // Afterwards, keep checking for a splash started outside the app.
        startDiscovery()

        // A pinned flyout comes back pinned, where the user left it.
        if config.panelPinned {
            store.panelPinned = true
            DispatchQueue.main.async { [weak self] in self?.restorePinnedPanel() }
        }

        // Keep the system's login item in step with the saved preference
        // (it drifts if the user toggles it in System Settings).
        _ = syncLaunchAtLogin(config.launchAtLogin)

        // While pinned and dragged, remember where the flyout sits.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.store.panelPinned,
                  let w = note.object as? NSWindow, w === self.panel else { return }
            self.persistPanelState()
        }

        // Route every window close through windowWillClose — the Settings
        // scene's window has no delegate to assign, so the NSWindowDelegate
        // method alone would never see it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.windowWillClose(note)
        }

        // Debug hook: SPLASHMB_AUTOSHOW=panel|settings|both opens the flyout,
        // the settings window (or both) shortly after launch.
        if let mode = ProcessInfo.processInfo.environment["SPLASHMB_AUTOSHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                if mode == "settings" { self.openSettings() } else { self.togglePanel() }
                if mode == "both" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.openSettings()
                    }
                }
            }
        }

        // Debug hook: SPLASHMB_COLOR_PANEL=<gauge id> opens that gauge's
        // color panel shortly after launch.
        if let id = ProcessInfo.processInfo.environment["SPLASHMB_COLOR_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.openGaugeColorPanel(id: id)
            }
        }

        // Debug hook: SPLASHMB_COLOR_SIMULATE=<gauge id>:#RRGGBB plays back
        // one panel edit through the same path a user pick takes.
        if let spec = ProcessInfo.processInfo.environment["SPLASHMB_COLOR_SIMULATE"],
           let sep = spec.firstIndex(of: ":") {
            let id = String(spec[..<sep])
            let hex = String(spec[spec.index(after: sep)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                guard let self, let color = Color(hex: hex) else { return }
                self.gaugeColorPanel.bind(id: id)
                self.gaugeColorPanel.handleColor(NSColor(color))
            }
        }
    }

    /// Every quit — the flyout's ⏻, ⌘Q from a focused window — asks here.
    /// While the app owns a running server, a checkbox (off by default, so
    /// the quit stops the server as before) can leave it running; a forced
    /// terminate (the relaunch after an update or a language change) skips
    /// the dialog.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !forceTerminate else { return .terminateNow }
        if proc.ownsRunningChild {
            switch confirmQuitWithRunningServer() {
            case .cancel:
                return .terminateCancel
            case .quit(let stopServer):
                leaveServerRunningOnQuit = !stopServer
                return .terminateNow
            }
        }
        let info = String(localized: "A splash server started outside the app keeps running.")
        return confirm(String(localized: "Quit Splash Menu Bar?"), info: info,
                       button: String(localized: "Quit"))
            ? .terminateNow : .terminateCancel
    }

    private enum QuitWithServerChoice {
        case cancel
        case quit(stopServer: Bool)
    }

    /// The quit confirmation while the app's own server is running. The
    /// checkbox is off by default, i.e. the quit stops the server; on, the
    /// server is left running — reparented to launchd, and the next start
    /// adopts it on the configured port.
    private func confirmQuitWithRunningServer() -> QuitWithServerChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Splash Menu Bar?")
        alert.informativeText = String(localized: "The splash server this app started will be stopped.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let leave = NSButton(
            checkboxWithTitle: String(localized: "Leave the splash server running"),
            target: nil, action: nil)
        alert.accessoryView = leave
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        return .quit(stopServer: leave.state != .on)
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistPanelState()
        // Quitting the app stops our child and its engine (waiting briefly so
        // nothing is orphaned) but leaves an externally started server alone
        // — unless the quit dialog's checkbox left the app's own server
        // running.
        if !leaveServerRunningOnQuit {
            proc.stopChildBeforeQuit()
        }
    }

    /// Sets the status item text; a "●" is drawn yellow while starting and
    /// green when serving — the flyout's status dot colors.
    private func setStatusTitle(_ title: String, startingUp: Bool) {
        guard let button = statusItem?.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: font])
        let dotColor = startingUp ? NSColor.systemYellow : NSColor.systemGreen
        let ns = title as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "●", options: [], range: search)
            if r.location == NSNotFound { break }
            attributed.addAttributes([
                .foregroundColor: dotColor,
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

    /// Where the flyout sits when it isn't pinned and moved: just below the
    /// menu bar, under the status item, clamped into the screen.
    private func anchoredOrigin(for size: NSSize, anchor: NSButton, anchorWindow: NSWindow) -> NSPoint {
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 360, height: 640)
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = anchorFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 6), max(visible.minX + 6, visible.maxX - size.width - 6))
        return NSPoint(x: x, y: visible.maxY - size.height)
    }

    /// `keepingTopLeft`: rebuild at this top-left corner (a pinned flyout the
    /// user moved) instead of under the status item.
    private func showPanel(anchor: NSButton, anchorWindow: NSWindow, keepingTopLeft: NSPoint? = nil) {
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 360, height: 640)

        // Measure the unclipped content first.
        let handler: (MenuAction) -> Void = { [weak self] in self?.handleAction($0) }
        let colorPanelHandler: (String) -> Void = { [weak self] id in
            self?.openGaugeColorPanel(id: id)
        }
        let plain = NSHostingView(rootView: MetricsView(
            store: store, config: config, settings: settingsModel,
            onAction: handler,
            onOpenGaugeColorPanel: colorPanelHandler))
        let fitting = plain.fittingSize
        let maxH = visible.height - 8
        let hosting: NSHostingView<MetricsView>
        if fitting.height > maxH {
            hosting = NSHostingView(rootView: MetricsView(
                store: store, config: config, settings: settingsModel,
                maxHeight: maxH,
                onAction: handler, onOpenGaugeColorPanel: colorPanelHandler))
        } else {
            hosting = plain
        }
        let size = hosting.fittingSize

        // Place the card just below the menu bar, under the status item,
        // clamped into the screen — never off the top or the sides.
        var origin = anchoredOrigin(for: size, anchor: anchor, anchorWindow: anchorWindow)
        if let topLeft = keepingTopLeft {
            // A pinned panel keeps its saved corner, clamped into the visible
            // frame — a monitor may have gone away or changed size since.
            let minX = visible.minX + 6
            let maxX = visible.maxX - size.width - 6
            let x = min(max(topLeft.x, minX), max(minX, maxX))
            var y = topLeft.y - size.height
            y = min(y, visible.maxY - size.height)
            y = max(y, visible.minY + 6)
            origin = NSPoint(x: x, y: y)
        }
        let x = origin.x, y = origin.y

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
        // Draggable only while pinned (see WindowDragArea in the view).
        p.isMovable = store.panelPinned
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
    /// under the menu bar. Switches both ways between the plain and scrolling
    /// layouts — a flyout that shrinks back under the cap must not stay
    /// stuck in the scrolling layout.
    private func resizePanelToFit() {
        guard panelVisible, let p = panel else { return }
        let maxH = ((p.screen ?? NSScreen.main)?.visibleFrame.height ?? 640) - 8
        let handler: (MenuAction) -> Void = { [weak self] in self?.handleAction($0) }
        let colorPanelHandler: (String) -> Void = { [weak self] id in
            self?.openGaugeColorPanel(id: id)
        }
        let plain = NSHostingView(rootView: MetricsView(
            store: store, config: config, settings: settingsModel,
            onAction: handler, onOpenGaugeColorPanel: colorPanelHandler))
        let plainSize = plain.fittingSize
        let shouldScroll = plainSize.height > maxH
        if panelScrolls == shouldScroll {
            if !panelScrolls && abs(plainSize.height - p.frame.height) > 0.5 {
                var frame = p.frame
                frame.origin.y = frame.maxY - plainSize.height
                frame.size.height = plainSize.height
                p.setFrame(frame, display: true)
            }
            return
        }
        // The layout mode changed: rebuild the panel in the new mode. A
        // pinned panel keeps its corner (clamped into the screen).
        guard let button = statusItem.button, let win = button.window else { return }
        let topLeft = store.panelPinned ? NSPoint(x: p.frame.minX, y: p.frame.maxY) : nil
        closePanel()
        showPanel(anchor: button, anchorWindow: win, keepingTopLeft: topLeft)
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

    // MARK: - Notifications

    private static let startActionID = "splash.start"
    private static let crashCategoryID = "splash.crash"
    /// Tags the "Request finished" banner so a click can reopen the flyout
    /// (it carries no action button).
    private static let requestFinishedCategoryID = "splash.requestFinished"

    /// Crash notifications carry a "Start splash" action; requesting
    /// authorization once at launch surfaces the system prompt.
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startActionID,
                                         title: "Start splash", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.crashCategoryID,
                                   actions: [start], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts the crash notification unless a splash we didn't start is
    /// serving the port: then the child died with "address in use" behind a
    /// healthy external server and there is no outage to announce. The port
    /// is re-probed rather than trusting `store.endpointAlive`, which can
    /// still reflect our own child from the last poll.
    private func postCrashNotificationIfNeeded(_ info: CrashInfo) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await StatusClient.probe(port: self.config.port, timeout: 1) {
            case .splash:
                return   // healthy external server: no outage to announce
            case .other:
                // A non-splash service holds the port: the flyout's "port in
                // use" card explains; "the server is stopped" would lie.
                self.store.portOccupiedByOther = true
                return
            case .nothing:
                break
            }
            self.postCrashNotification(info)
        }
    }

    private func postCrashNotification(_ info: CrashInfo) {
        guard config.notificationsEnabled(.crash) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "splash exited")
        content.body = String(localized: "\(info.description) — the server is stopped.")
        content.sound = .default
        content.categoryIdentifier = Self.crashCategoryID
        let request = UNNotificationRequest(identifier: Self.crashCategoryID,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Posts a plain banner (no actions), like the crash one. The title is
    /// the identifier by default, so a repeated banner replaces its
    /// predecessor; a caller that wants each one kept passes an identifier.
    private func postNotification(title: String, body: String,
                                  identifier: String? = nil,
                                  category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category ?? ""
        let request = UNNotificationRequest(identifier: identifier ?? title,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The flyout isn't always in view: these states post a banner.
    private func watchNotificationTriggers() {
        // The model finished downloading: splash announces a fetch during
        // startup and later reports Ready; only then is it worth a ping.
        store.$readyModel
            .dropFirst()
            .filter { $0 != nil }
            .sink { [weak self] model in
                guard let self else { return }
                guard self.store.modelDownloadedThisStartup else { return }
                self.store.modelDownloadedThisStartup = false
                guard self.config.notificationsEnabled(.modelReady) else { return }
                self.postNotification(title: String(localized: "Model ready"),
                                      body: String(localized: "\(model ?? String(localized: "the model")) finished downloading, is loaded and serving."))
            }
            .store(in: &cancellables)

        // Thermal state crossed into the hot states (nominal/fair stay quiet).
        store.$thermalState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self, let state,
                      self.config.notificationsEnabled(.thermal) else { return }
                switch state {
                case "serious":
                    self.postNotification(title: String(localized: "Thermal: serious"),
                                          body: String(localized: "The Mac is running hot (thermal state \"serious\"): the CPU and GPU are being throttled, so generation slows down."))
                case "critical":
                    self.postNotification(title: String(localized: "Thermal: critical"),
                                          body: String(localized: "The Mac is overheating (thermal state \"critical\"): heavy throttling until it cools down."))
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // A request made no progress for a minute: likely a hang.
        store.$requestStuck
            .removeDuplicates()
            .sink { [weak self] stuck in
                guard let self, stuck,
                      self.config.notificationsEnabled(.requestStuck) else { return }
                self.postNotification(title: String(localized: "Request appears stuck"),
                                      body: String(localized: "A request has made no progress for 1 minute. Restart usually clears it."))
            }
            .store(in: &cancellables)

        // A request long enough to mean the user is away finished: the
        // Done line carries its output count and speed. App-launched
        // servers only (an adopted server has no log to parse). Each
        // banner is kept (a unique identifier) so back-to-back finishes
        // don't replace one another; clicking one reopens the flyout.
        store.requestFinished
            .filter(\.worthNotifying)
            .sink { [weak self] r in
                guard let self,
                      self.config.notificationsEnabled(.requestFinished) else { return }
                self.postNotification(
                    title: String(localized: "Request finished"),
                    body: String(localized: "\(Fmt.int(r.output)) tok · \(Fmt.double(r.tokensPerSecond, 0)) t/s"),
                    identifier: UUID().uuidString,
                    category: Self.requestFinishedCategoryID)
            }
            .store(in: &cancellables)

        // The weights were released from memory after idleness.
        store.$weightsReleased
            .removeDuplicates()
            .sink { [weak self] released in
                guard let self, released,
                      self.config.notificationsEnabled(.weightsReleased) else { return }
                self.postNotification(title: String(localized: "splash released the model"),
                                      body: String(localized: "After idleness, splash freed the model weights from memory to give the RAM back. The next request restores them and will be slower."))
            }
            .store(in: &cancellables)
    }

    // MARK: - Pinned flyout

    /// Persists the flyout's pin state and, while pinned, its top-left
    /// corner (the frame's minX/maxY — AppKit's origin is bottom-left), so a
    /// restart drops the flyout back where it was.
    private func persistPanelState() {
        config.panelPinned = store.panelPinned
        if store.panelPinned, let p = panel {
            config.pinnedPanelTopLeft = SplashConfig.PanelTopLeft(
                x: Double(p.frame.minX), y: Double(p.frame.maxY))
        } else {
            config.pinnedPanelTopLeft = nil
        }
        config.save()
    }

    /// Re-opens a previously pinned flyout, at its saved corner when that
    /// corner is still on a screen (a monitor may have gone away).
    private func restorePinnedPanel() {
        guard let button = statusItem.button, let win = button.window,
              !panelVisible else { return }
        var topLeft = config.pinnedPanelTopLeft.map { NSPoint(x: $0.x, y: $0.y) }
        if let tl = topLeft,
           !NSScreen.screens.contains(where: { $0.frame.contains(tl) }) {
            topLeft = nil
        }
        showPanel(anchor: button, anchorWindow: win, keepingTopLeft: topLeft)
    }

    // MARK: - Gauge colors

    /// A gauge color pick from the color panel: flyout and in-memory config
    /// update live; the file write is coalesced by GaugeColorPanel.
    private func applyGaugeColor(id: String, color: Color) {
        let hex = color.hexString
        store.gaugeColors[id] = hex
        config.gaugeColors[id] = hex
    }

    /// The shared system color panel for gauge picks.
    private lazy var gaugeColorPanel = GaugeColorPanel(
        onLive: { [weak self] id, color in
            self?.applyGaugeColor(id: id, color: color)
        },
        onCommit: { [weak self] in
            _ = self?.config.save()
        })

    private func openGaugeColorPanel(id: String) {
        gaugeColorPanel.open(for: id, current: store.currentGaugeColor(id: id))
    }

    // MARK: - Login item

    /// Registers or unregisters the app as a login item so the system's
    /// state matches `enabled`; the error if the change failed.
    private func syncLaunchAtLogin(_ enabled: Bool) -> Error? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
            return nil
        } catch {
            return error
        }
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
                self.store.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                // The configured port, or a splash found running elsewhere.
                let port = self.store.serverPort ?? self.config.port
                // Time out well before a minute so a stalled server can't
                // freeze the flyout; the next poll tries again.
                let timeout = min(max(interval * 2, 2), 10)
                if let doc = await StatusClient.fetch(port: port, timeout: timeout) {
                    self.store.apply(status: doc)
                    // Feed the flyout's TODAY section: daily stats derive
                    // from the lifetime counters, so this works for adopted
                    // external servers too (which have no log to parse).
                    // The port is part of the baseline's identity, so a
                    // switch to a different server re-baselines.
                    StatsStore.shared.updateBaselines(
                        completed: self.store.completedCount,
                        output: self.store.totalOutputTokens,
                        serverPort: port
                    )
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
            store.showSetupTip = false
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
            store.serverPort = nil   // ours restarts on the configured port
            proc.restart(with: config)
        case .settings:
            dismissPanel()
            openSettings()
        case .requests:
            dismissPanel()
            openRequestLog()
        case .switchModel(let id):
            dismissPanel()
            switchModel(to: id)
        case .update:
            dismissPanel()
            updateSplash()
        case .updateApp:
            dismissPanel()
            updateApp()
        case .dismissSetupTip:
            store.showSetupTip = false
        case .togglePin:
            store.panelPinned.toggle()
            persistPanelState()
            guard let p = panel else { return }
            // Pinned, it floats below alerts and dialogs instead of over them,
            // and can be dragged anywhere.
            p.level = store.panelPinned ? .floating : .popUpMenu
            p.isMovable = store.panelPinned
            if !store.panelPinned, let button = statusItem.button, let win = button.window {
                // Unpinned: snap back under the status item.
                let origin = anchoredOrigin(for: p.frame.size, anchor: button, anchorWindow: win)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    p.animator().setFrame(NSRect(origin: origin, size: p.frame.size), display: true)
                }
            }
        case .quit:
            // The dialog lives in applicationShouldTerminate, so this and
            // ⌘Q get the same confirmation.
            dismissPanel()
            NSApp.terminate(nil)
        }
    }

    /// Asks the user to confirm a disruptive action; true if they agree.
    /// Message, info and button arrive already localized (call sites use
    /// String(localized:)) because LSK→String has no public conversion.
    private func confirm(_ message: String, info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - splash installation

    /// Starts `splash serve`, or asks the user to install `splash` first.
    /// When a splash already serving the configured port (started outside
    /// the app) answers the probe, it is adopted: spawning a child would
    /// just die with "address in use".
    private func startServer() {
        guard SplashInstaller.isSplashInstalled else {
            promptInstall()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await StatusClient.probe(port: self.config.port, timeout: 1.5) {
            case .splash:
                self.adopt(port: self.config.port)   // external splash on our port
            case .other:
                // Something that isn't splash holds the port: spawning a
                // child would just die with "address in use" — say so.
                self.store.portOccupiedByOther = true
                self.store.state = .crashed(CrashInfo(
                    code: 0, bySignal: false, note: "port in use"))
            case .nothing:
                // Our own server, on the configured port.
                self.store.serverPort = nil
                self.proc.externalPort = nil
                self.proc.start(self.config)
            }
        }
    }

    // MARK: - Finding a running splash

    /// The port of a splash server that's already running, if any: the
    /// configured port first, then any port a splash process listens on
    /// (each confirmed with a /status probe).
    private func findRunningServer() async -> Int? {
        let configured = config.port
        if case .splash = await StatusClient.probe(port: configured, timeout: 1.5) {
            return configured
        }
        let candidates = await Task.detached(priority: .utility) {
            SplashProcess.discoverServerPorts()
        }.value
        for port in candidates where port != configured {
            if case .splash = await StatusClient.probe(port: port, timeout: 1.5) {
                return port
            }
        }
        return nil
    }

    /// Watch the splash on `port` (the poll loop, Stop and Restart follow it).
    private func adopt(port: Int) {
        let external = port == config.port ? nil : port
        store.serverPort = external
        proc.externalPort = external
        store.showSetupTip = false
        startPolling()   // poll it now rather than after the interval
    }

    /// Connects to a running splash if there is one; otherwise starts ours
    /// (`startIfNone`) or shows the "pick a model, then Start" tip — opening
    /// the flyout so it's seen when `openFlyout` (first launch).
    private func connectOrSetUp(openFlyout: Bool, startIfNone: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let port = await self.findRunningServer() {
                self.adopt(port: port)
                return
            }
            if startIfNone {
                self.startServer()
                return
            }
            self.store.showSetupTip = true
            if openFlyout, !self.panelVisible,
               let button = self.statusItem.button, let win = button.window {
                self.showPanel(anchor: button, anchorWindow: win)
            }
        }
    }

    /// Every few seconds while no server is connected (and the app isn't
    /// running or starting its own), look for a splash started elsewhere —
    /// e.g. `splash serve` in a terminal — and connect to it.
    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.discoveryInterval * 1_000_000_000))
                guard let self else { return }
                guard !self.store.effectiveRunning, !self.store.isStartingUp,
                      SplashInstaller.isSplashInstalled
                else { continue }
                if let port = await self.findRunningServer(),
                   !self.store.effectiveRunning {   // nothing else connected meanwhile
                    self.adopt(port: port)
                }
            }
        }
    }

    /// `thenStart`: start the server once installed (the user pressed Start
    /// or start-on-launch is on); otherwise show the setup tip instead.
    private func promptInstall(thenStart: Bool = true) {
        if let w = installWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let brew = SplashInstaller.brewPath

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "splash is not installed")
        if brew != nil {
            alert.informativeText = String(localized: """
            Splash Menu Bar needs the `splash` command-line tool to run the server.

            Install it yourself with:
                \(SplashInstaller.installCommand)

            or let Splash Menu Bar run that command for you now.
            """)
            alert.addButton(withTitle: String(localized: "Install with Homebrew"))
        } else {
            alert.informativeText = String(localized: """
            Splash Menu Bar needs the `splash` command-line tool to run the server, \
            and Homebrew wasn't found to install it.

            Install Homebrew from https://brew.sh, then run:
                \(SplashInstaller.installCommand)

            Afterwards, press Start in the menu bar flyout.
            """)
        }
        alert.addButton(withTitle: String(localized: "Copy Command"))
        alert.addButton(withTitle: String(localized: "Not Now"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let copyButton: NSApplication.ModalResponse = brew != nil ? .alertSecondButtonReturn : .alertFirstButtonReturn

        if let brew, response == .alertFirstButtonReturn {
            runInstall(brew: brew, thenStart: thenStart)
        } else if response == copyButton {
            copyCommand(SplashInstaller.installCommand)
        }
        // "Not Now" / after copying: stay stopped; Start in the flyout re-checks.
    }

    private func runInstall(brew: String, thenStart: Bool) {
        let model = InstallModel()
        let view = InstallView(model: model) { [weak self] installed in
            guard let self else { return }
            self.closeInstallWindow()
            if installed {
                self.checkSplashUpdate()
                self.connectOrSetUp(openFlyout: !thenStart, startIfNone: thenStart)
            }
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = String(localized: "Splash Menu Bar — Install splash")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
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

    // MARK: - splash updates

    /// Compares the installed splash with the newest release and stores the
    /// answer in the flyout state; a newer release shows the update card.
    /// Runs on the main actor but never blocks (the `--version` probe is
    /// detached).
    private func checkSplashUpdate() {
        Task { @MainActor [weak self] in
            let installed = await Task.detached(priority: .utility) {
                SplashInstaller.installedVersion()
            }.value
            let latest = await SplashInstaller.fetchLatestVersion()
            guard let self else { return }
            self.store.installedVersion = installed
            self.store.latestVersion = latest
        }
    }

    /// The flyout's "Update Splash": confirm the upgrade, run it through
    /// Homebrew, then offer a restart so the server picks up the new
    /// version.
    private func updateSplash() {
        guard store.updateAvailable else { return }
        let latest = store.latestVersion ?? "?"
        let current = store.installedVersion ?? "?"
        guard confirm(String(localized: "Update splash to \(latest)?"),
                      info: String(localized: "You have splash \(current). This runs:\n    brew upgrade \(SplashInstaller.formula)\nA progress window shows what Homebrew is doing."),
                      button: String(localized: "Update")) else { return }
        guard let brew = SplashInstaller.brewPath else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Homebrew not found")
            alert.informativeText = String(localized: "The update needs Homebrew to run:\n    brew upgrade \(SplashInstaller.formula)")
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        runUpgrade(brew: brew)
    }

    private func runUpgrade(brew: String) {
        let model = InstallModel()
        let view = InstallView(model: model) { [weak self] updated in
            guard let self else { return }
            self.closeInstallWindow()
            self.checkSplashUpdate()
            guard updated else { return }
            // The running server (if any) still uses the old binary until it
            // restarts; a stopped server picks the new version up on Start.
            guard self.store.effectiveRunning,
                  self.confirm(String(localized: "Restart the splash server?"),
                               info: String(localized: "splash was updated, but the running server still uses the old version until it restarts. Requests in progress are cancelled."),
                               button: String(localized: "Restart")) else { return }
            self.store.resetForRestart()
            self.store.serverPort = nil   // ours restarts on the configured port
            self.proc.restart(with: self.config)
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = String(localized: "Splash Menu Bar — Update splash")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        installModel = model
        installWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.job = .upgradeSplash
        model.start(brew: brew)
    }

    // MARK: - App updates

    /// Compares the running app with the newest GitHub release and stores
    /// the answer in the flyout state; a newer release shows the app
    /// update card.
    private func checkAppUpdate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = await AppUpdater.fetchLatestVersion()
            self.store.appInstalledVersion = AppUpdater.currentVersion
            self.store.appLatestVersion = latest
        }
    }

    /// The flyout's "Update App": confirm the upgrade, run it through
    /// Homebrew, then relaunch the app onto the new version.
    private func updateApp() {
        guard store.appUpdateAvailable else { return }
        let latest = store.appLatestVersion ?? "?"
        let current = store.appInstalledVersion ?? "?"
        guard let brew = SplashInstaller.brewPath else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Homebrew not found")
            alert.informativeText = String(localized: "The update needs Homebrew to run:\n    \(AppUpdater.updateCommandLine)")
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        // A manual copy (not a Homebrew install) can't be upgraded by brew.
        guard AppUpdater.isInstalledViaHomebrew(brew: brew) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Not installed through Homebrew")
            alert.informativeText = String(localized: "This copy of Splash Menu Bar isn't a Homebrew install, so brew can't update it.\nInstall it once with:\n    \(AppUpdater.installCommand)\nor download the new release from GitHub.")
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let commands = AppUpdater.updateCommands
            .map { "    brew " + $0.joined(separator: " ") }
            .joined(separator: "\n")
        guard confirm(String(localized: "Update Splash Menu Bar to \(latest)?"),
                      info: String(localized: "You have \(current). This runs:\n\(commands)\nA progress window shows what Homebrew is doing; the app relaunches afterwards."),
                      button: String(localized: "Update")) else { return }
        runAppUpdate(brew: brew)
    }

    private func runAppUpdate(brew: String) {
        let model = InstallModel()
        model.job = .updateApp
        let view = InstallView(model: model) { [weak self] updated in
            guard let self else { return }
            self.closeInstallWindow()
            self.store.appLatestVersion = nil
            guard updated else { return }
            guard self.confirm(String(localized: "Restart Splash Menu Bar?"),
                               info: String(localized: "The new version starts now; anything in progress in this one is lost."),
                               button: String(localized: "Restart")) else { return }
            self.relaunchApp()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = String(localized: "Splash Menu Bar — Update app")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        installModel = model
        installWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.start(brew: brew)
    }

    /// Relaunches the app (the updater and the language picker). A running
    /// splash server survives: it reparents to launchd and the new instance
    /// picks it up on the configured port.
    func relaunch() {
        relaunchApp()
    }

    /// brew replaced the bundle in place, so launching the same path runs
    /// the new version; terminate this instance once it is up.
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn't relaunch Splash Menu Bar")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    return
                }
                // No quit dialog, and the server survives: the new instance
                // picks it up on the configured port.
                self.forceTerminate = true
                self.leaveServerRunningOnQuit = true
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Settings window

    /// Opens the standard Settings scene's window. The app is an
    /// accessory, so it must re-activate or the window comes back behind
    /// the frontmost app's windows.
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The Settings scene installs a "Settings…" item (⌘,) in the app
        // menu whose action is SwiftUI's internal menuAction: — perform
        // the item itself rather than guessing a selector.
        if let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu,
           let item = appMenu.items.first(where: {
               $0.keyEquivalent == ","
               && $0.keyEquivalentModifierMask == .command
               && $0.action != nil
           }) {
            NSApp.sendAction(item.action!, to: item.target, from: item)
            return
        }
        // Older systems wire the item to a real selector instead.
        for sel in [Selector(("showSettingsWindow:")), Selector(("showPreferencesWindow:"))]
        where NSApp.sendAction(sel, to: nil, from: nil) { break }
    }

    /// The standard Settings scene's window: the app's only non-panel,
    /// non-status-bar window besides the install and manage-models windows
    /// (the tabbed title is the current tab's name, so the window can't be
    /// found by its title).
    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { w in
            !(w is NSPanel)
            && !w.className.contains("StatusBar")
            && w !== installWindow
            && w !== modelManageWindow
        }
    }

    /// Closes the settings window (Save and Cancel both end here; the
    /// title bar's close button goes through windowWillClose directly).
    func dismissSettings() {
        (settingsWindow() ?? NSApp.keyWindow)?.performClose(nil)
    }

    /// What Save does: validate the system-side change, then persist the
    /// new config and restart splash if any serve option changed.
    func applySettings(_ saved: SplashConfig) {
        var new = saved
        // The login item is synced with the system before saving, so
        // a failed change is never persisted as the preference.
        if new.launchAtLogin != config.launchAtLogin,
           let error = syncLaunchAtLogin(new.launchAtLogin) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            let message: String = new.launchAtLogin
                ? String(localized: "Couldn't enable launch at login")
                : String(localized: "Couldn't turn off launch at login")
            alert.messageText = message
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return   // the settings window stays open
        }
        // The flyout's live pin state and position win over the
        // form's copy (the panel may have been moved while open),
        // and its gauge colors win over the form's (a right-click
        // pick may have happened while the form was open) — unless
        // "Reset to defaults" cleared them.
        new.panelPinned = config.panelPinned
        new.pinnedPanelTopLeft = config.pinnedPanelTopLeft
        if !settingsModel.resetToDefaultsApplied {
            new.gaugeColors = store.gaugeColors
        }
        // Saving Settings is the step the setup tip asks for.
        store.showSetupTip = false
        if new != config {
            // Only splash options restart the server; the refresh
            // interval is the app's own and applies on the next poll.
            let serverChanged = new.serveArguments != config.serveArguments
            config = new
            if !new.save() {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn't save settings")
                alert.informativeText = String(localized: "The changes apply for this session, but the config file couldn't be written: \(new.saveError ?? "unknown error"). They'll be lost when the app quits.")
                alert.addButton(withTitle: String(localized: "OK"))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            if serverChanged {
                store.resetForRestart()
                store.serverPort = nil   // ours restarts on the configured port
                proc.restart(with: new)
            } else {
                // App-side options only: the running server keeps running,
                // but the next start (an auto-restart included) reads them.
                proc.updateConfig(new)
                // Wake the poll loop now instead of after the old interval.
                startPolling()
            }
            // The flyout holds a copy of the config; a pinned one stays
            // open, so rebuild it with the new settings in place.
            rebuildPanelIfVisible()
        }
        dismissSettings()
    }

    /// The flyout's Model menu: persist the new `--model`, and when a
    /// server is up, confirm and restart it with the new model (the same
    /// restart the Restart button does, with the model swapped in). With
    /// no server up the switch only updates what the next Start uses.
    private func switchModel(to id: String) {
        guard id != config.model else { return }
        let running = store.effectiveRunning
        var new = config
        new.model = id
        if running {
            let label = settingsModel.modelChoices.first { $0.id == id }?.label ?? id
            guard confirm(String(localized: "Switch the splash model to \(label)?"),
                          info: String(localized: "The server restarts with it; requests in progress are cancelled."),
                          button: String(localized: "Switch")) else { return }
        }
        config = new
        if !new.save() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn't save settings")
            alert.informativeText = String(localized: "The changes apply for this session, but the config file couldn't be written: \(new.saveError ?? "unknown error"). They'll be lost when the app quits.")
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        // The settings form is created once and kept for the next open;
        // it must show the new model when that happens.
        settingsModel.model = id
        settingsModel.customModel = !SplashModels.catalog.contains { $0.id == id }
        if running {
            store.resetForRestart()
            store.serverPort = nil   // ours restarts on the configured port
            proc.restart(with: new)
        }
    }

    // MARK: - Manage models window

    func openManageModels() {
        deferPanelReopen = true
        if let w = modelManageWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = ModelManageModel()
        model.rescan()
        let view = ModelManageView(model: model) { [weak self] in
            self?.closeModelManageWindow()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = String(localized: "Splash Menu Bar — Manage models")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        modelManageWindow = w
        modelManageModel = model
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.closePanel() }
        w.makeKeyAndOrderFront(nil)
    }

    private func closeModelManageWindow() {
        // The in-window Close button; close() posts willCloseNotification
        // synchronously, where the bookkeeping and the flyout decision
        // live (with the title-bar close).
        modelManageWindow?.close()
    }

    // MARK: - Recent requests window

    private var requestLogWindow: NSWindow?

    /// Opens the log of finished requests (from the server's log — an
    /// adopted, externally started server has no log, so its window is
    /// empty by design). Reopening focuses the existing window.
    func openRequestLog() {
        if let w = requestLogWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = RequestLogView(store: store)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = String(localized: "Splash Menu Bar — Recent requests")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        requestLogWindow = w
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.closePanel() }
        w.makeKeyAndOrderFront(nil)
    }

    /// Rebuilds an open flyout (e.g. after Settings changed), keeping a
    /// pinned flyout where the user put it.
    private func rebuildPanelIfVisible() {
        guard panelVisible, let p = panel,
              let button = statusItem.button, let win = button.window else { return }
        let topLeft = store.panelPinned ? NSPoint(x: p.frame.minX, y: p.frame.maxY) : nil
        closePanel()
        showPanel(anchor: button, anchorWindow: win, keepingTopLeft: topLeft)
    }

    private func reopenPanel() {
        guard let button = statusItem.button, let win = button.window, !panelVisible else { return }
        showPanel(anchor: button, anchorWindow: win)
    }
}

extension AppDelegate {
    /// Every window close funnels here through the
    /// `NSWindow.willCloseNotification` observer installed in
    /// applicationDidFinishLaunching (the Settings scene's window has no
    /// delegate to assign). Each app window is matched by identity, and
    /// the flyout is only reopened for the window that replaced it — so
    /// unrelated windows, and third-party windows that reach this app
    /// (TUINSWindow from Arc in practice), never trigger a reopen.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, NSApp.windows.contains(w) else { return }
        if w === installWindow {
            // Closed via the title bar: stop a running install.
            installModel?.cancel()
            installWindow = nil
            installModel = nil
            // The user came here from the flyout (install prompt, Update
            // Splash, Update App); back to it.
            reopenPanel()
            return
        }
        if w === modelManageWindow {
            // Decide the flyout's fate before clearing the reference:
            // settingsWindow() excludes the manage window by identity,
            // which only works while modelManageWindow still points at it.
            let settingsOpen = settingsWindow() != nil
            // Stop a running download so it isn't orphaned (the Close
            // button is disabled while one runs, but a title-bar close
            // isn't).
            modelManageModel?.cancelDownload()
            modelManageWindow = nil
            modelManageModel = nil
            // The cache may have changed; refresh the picker's list.
            settingsModel.rescan()
            deferPanelReopen = false
            // Manage was opened from Settings; only restore the flyout
            // once Settings is gone too, never over a still-open one.
            if !settingsOpen { reopenPanel() }
            return
        }
        if w === requestLogWindow {
            requestLogWindow = nil
            // It replaced the flyout (opened from it); back to the flyout.
            reopenPanel()
            return
        }
        // The standard Settings scene's window (tabbed — its title is the
        // current tab's name, not "<App> Settings"): close it and the
        // flyout it replaced. Match by identity, not by "any other
        // window": foreign windows (TUINSWindow from Arc in practice)
        // pass the NSApp.windows guard above and must not reopen the
        // flyout.
        if w === settingsWindow(), !deferPanelReopen {
            reopenPanel()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// An accessory app never "activates"; present the banner and sound
    /// anyway so a crash is seen even with the flyout closed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler:
                                @escaping () -> Void) {
        defer { completionHandler() }
        if response.actionIdentifier == Self.startActionID {
            startServer()
            return
        }
        // A plain click on "Request finished": bring the flyout back, since
        // the point of the banner is to call the user back to the app.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.categoryIdentifier
                == Self.requestFinishedCategoryID else { return }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.reopenPanel()
        }
    }
}
