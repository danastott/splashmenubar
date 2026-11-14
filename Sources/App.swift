import SwiftUI

/// Entry point. The app has no main window — it lives in the menu bar
/// (see AppDelegate) — so its only SwiftUI scene is the standard
/// Settings scene: the system provides the window chrome, the ⌘,
/// shortcut, and a single window for the app's lifetime.
@main
struct SplashMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsSceneView()
        }
    }
}
