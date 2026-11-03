import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel used for the metrics flyout.
final class MetricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        close()
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
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private var settingsWindow: NSWindow?
    private var pollTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = SplashConfig.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "cpu",
                accessibilityDescription: "Splash"
            )
            button.image?.isTemplate = true
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

        Publishers.CombineLatest4(
            store.$state, store.$liveTokensPerSecond, store.$requests, store.$endpointAlive
        )
            .map { state, live, requests, endpointAlive -> String in
                let tps = live ?? requests.last(where: { !$0.isStarted })?.tokensPerSecond
                switch state {
                case .running, .starting:
                    if let tps { return String(format: " %.1f t/s", tps) }
                    return " ⏳"
                case .stopped, .crashed:
                    // A server is answering /status even though it is not our
                    // child (started externally or left over): show its speed.
                    if endpointAlive {
                        if let tps { return String(format: " %.1f t/s", tps) }
                        return " ⏳"
                    }
                    if case .crashed = state { return " ✕" }
                    return ""
                }
            }
            .removeDuplicates()
            .sink { [weak self] title in
                self?.statusItem?.button?.title = title
            }
            .store(in: &cancellables)

        startPolling()

        // Requirement: launching the menu bar app starts splash.
        proc.start(config)

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

    // MARK: - Panel

    @objc private func togglePanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        if panelVisible {
            closePanel()
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
        p.level = .popUpMenu
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = hosting

        panel = p
        p.orderFront(nil)
        p.makeKey()
        panelVisible = true
        installMonitors()
    }

    private func closePanel() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
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
                self.closePanel()
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
            self.closePanel()
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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
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
            closePanel()
            proc.start(config)
        case .stop:
            closePanel()
            store.resetForRestart()
            proc.stop()
        case .restart:
            closePanel()
            store.resetForRestart()
            proc.restart()
        case .settings:
            closePanel()
            openSettings()
        case .quit:
            NSApp.terminate(nil)
        }
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
                    self.config = new
                    new.save()
                    self.store.resetForRestart()
                    self.proc.restart()
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
        guard let w = notification.object as? NSWindow, w === settingsWindow else { return }
        settingsWindow = nil
        reopenPanel()
    }
}
