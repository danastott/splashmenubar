import AppKit
import SwiftUI

/// A gauge's color pick.
///
/// A `ColorPicker` (NSColorWell) cannot work inside a context menu — macOS
/// draws it as a disabled item — so the menu's "Color…" item opens the
/// shared system color panel instead, pre-selected with the gauge's current
/// color. The panel updates the gauge live while the user picks; the config
/// write is coalesced (one write per burst of changes, plus one when the
/// panel closes), so a drag doesn't write the file on every pixel.
final class GaugeColorPanel {
    /// One panel change, applied to the gauge (flyout + in-memory config;
    /// no file write).
    private let onLive: (String, Color) -> Void
    /// The config write, at the end of a change burst or on panel close.
    private let onCommit: () -> Void

    private let proxy = ColorPanelProxy()
    private var gaugeID: String?
    private var dirty = false
    private var saveTimer: Timer?
    /// How long after the last panel change to wait before writing.
    private let saveDelay: TimeInterval = 0.4
    private var closeObserver: NSObjectProtocol?

    init(onLive: @escaping (String, Color) -> Void,
         onCommit: @escaping () -> Void) {
        self.onLive = onLive
        self.onCommit = onCommit
        proxy.onColor = { [weak self] in self?.handleColor($0) }
    }

    /// Points the shared color panel at `id` and shows it, pre-selected
    /// with `current`.
    func open(for id: String, current: Color) {
        bind(id: id)
        let panel = NSColorPanel.shared
        panel.setTarget(proxy)
        panel.setAction(#selector(ColorPanelProxy.colorChanged(_:)))
        panel.isContinuous = true
        panel.color = NSColor(current)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        observeClose()
    }

    /// Which gauge the panel edits; the timer is reset so a pick for one
    /// gauge can't be committed under another.
    func bind(id: String) {
        gaugeID = id
        dirty = false
        saveTimer?.invalidate()
        saveTimer = nil
    }

    /// One panel edit (fires continuously while the user drags).
    func handleColor(_ color: NSColor) {
        guard let id = gaugeID else { return }
        onLive(id, Color(nsColor: color))
        dirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDelay,
                                         repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    /// Write the pending pick, if any.
    private func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard dirty else { return }
        dirty = false
        onCommit()
    }

    /// A pick has to survive the user closing the panel mid-burst.
    private func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: NSColorPanel.shared, queue: .main) { [weak self] _ in
                self?.flush()
        }
    }

    private final class ColorPanelProxy: NSObject {
        var onColor: ((NSColor) -> Void)?
        @objc func colorChanged(_ sender: NSColorPanel) {
            onColor?(sender.color)
        }
    }
}
