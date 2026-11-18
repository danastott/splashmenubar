import Foundation

/// Resolves a pluralized message from "<base>.<category>" keys in
/// Localizable.strings, selecting the CLDR plural category for the runtime
/// locale.
///
/// The rules for the common locales are implemented here because this SDK's
/// Foundation exposes no ICU plural API to Swift, and its stringsdict
/// `%#@var%` plural resolution is unreliable (it returns empty results or
/// crashes). Locales without an explicit rule fall back to the en-like
/// "1 = one, else other".
///
/// Keys, e.g. for base "files":
///     "files.one"   = "%lld file"
///     "files.other" = "%lld files"
/// A missing category key falls back to ".other".
///
/// The count is always the first format argument; `values` appends the rest.
enum Plural {
    static func category(_ count: Int, locale: Locale = .current) -> String {
        let id = locale.identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        func match(_ codes: String...) -> Bool {
            codes.contains { id == $0 || id.hasPrefix($0 + "-") }
        }
        switch true {
        // one / few / many (East Slavic + South Slavic)
        case match("ru", "uk", "bg", "sr", "mk"):
            let m10 = count % 10, m100 = count % 100
            if m10 == 1 && m100 != 11 { return "one" }
            if (2...4).contains(m10) && !(12...14).contains(m100) { return "few" }
            return "many"
        // one / few / many with a distinct singular
        case match("pl", "cs"):
            if count == 1 { return "one" }
            let m10 = count % 10, m100 = count % 100
            if (2...4).contains(m10) && !(12...14).contains(m100) { return "few" }
            return "many"
        case match("sl"):
            switch count % 100 {
            case 1: return "one"
            case 2: return "two"
            case 3...4: return "few"
            default: return "other"
            }
        // French takes 0 and 1 as singular
        case match("fr"):
            return count <= 1 ? "one" : "other"
        case match("ar"):
            if count == 0 { return "zero" }
            if count == 1 { return "one" }
            if count == 2 { return "two" }
            let m100 = count % 100
            if (3...10).contains(m100) { return "few" }
            if (11...99).contains(m100) { return "many" }
            return "other"
        case match("he"):
            if count == 0 { return "zero" }
            if count == 1 { return "one" }
            if count == 2 { return "two" }
            if count % 10 == 0 { return "many" }
            return "other"
        // No grammatical plural
        case match("ja", "ko", "zh"):
            return "other"
        default:
            // en, es, de, pt, it, nl, sv, ...
            return count == 1 ? "one" : "other"
        }
    }

    static func format(_ base: String, _ count: Int,
                       _ values: [String] = [],
                       bundle: Bundle = .main) -> String {
        let category = category(count)
        var template = "\(base).other"
        for key in ["\(base).\(category)", "\(base).other"] {
            let found = bundle.localizedString(forKey: key, value: key, table: nil)
            // A missing key is returned verbatim; plural key values always
            // contain a % placeholder, which the bare key doesn't.
            if found != key, found.contains("%") {
                template = found
                break
            }
        }
        let args: [CVarArg] = [count] + values
        return String(format: template, locale: Locale.current, arguments: args)
    }
}
