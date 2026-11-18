import Foundation

/// The UI language choice.
///
/// macOS resolves an app's language from the `AppleLanguages` default in
/// the app's own domain (the same key Finder's Get Info per-app language
/// picker writes) and reads it at process launch. NSBundle's runtime
/// `setPreferredLocalizations:` is gone from the public API on this OS, so
/// applying a change requires a relaunch.
///
/// The choice persists in `appLanguage` — not in the splash server's config
/// file, which `splash serve` would not understand — and `persist` mirrors
/// it into the app-domain `AppleLanguages`. "" = System: follow the
/// system's language when it is a shipped locale, otherwise the
/// development region (en).
enum AppLanguage {
    /// Native names for every shippable language code, including English
    /// (the development region). The picker lists everything except English;
    /// the "System" option uses this table to show the language it actually
    /// resolves to.
    static let displayNames: [(code: String, name: String)] = [
        ("en", "English"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("es", "Español"),
        ("pt-BR", "Português (Brasil)"),
        ("ru", "Русский"),
        ("zh-Hans", "简体中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    /// The selectable locales (everything except the development region).
    static var supported: [(code: String, name: String)] {
        displayNames.filter { $0.code != "en" }
    }

    /// The native name of the language "System" resolves to for this app:
    /// the first of the system's preferred languages the app ships, falling
    /// back to the development region (English).
    static var systemLanguageName: String {
        let available = Set(displayNames.map { $0.code })
        var code = "en"
        for lang in Locale.preferredLanguages {
            if let m = match(lang, in: available) {
                code = m
                break
            }
        }
        return displayNames.first { $0.code == code }?.name ?? code
    }

    /// "en-US" → "en", "zh-Hans-CN" → "zh-Hans", "pt-BR" → "pt-BR"; nil when
    /// no shippable locale matches (the system keeps looking further down
    /// its preference list, then falls back to English).
    static func match(_ id: String, in available: Set<String>) -> String? {
        let lower = id.lowercased()
        let candidates = available.filter {
            lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "-")
        }
        // Longest match wins (a "zh" locale would lose to "zh-Hans").
        return candidates.max { $0.count < $1.count }
    }

    static func selected(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "appLanguage") ?? ""
    }

    /// Persists the choice and mirrors it into the app-domain
    /// `AppleLanguages` default, which the system reads at the next launch.
    static func persist(_ code: String, defaults: UserDefaults = .standard) {
        defaults.set(code, forKey: "appLanguage")
        if code.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
    }
}
