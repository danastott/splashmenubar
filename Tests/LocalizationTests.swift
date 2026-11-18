import XCTest
@testable import SplashMenuBar

/// Exercises the shipped localization files through the same Foundation
/// lookup SwiftUI's String(localized:)/Text use, and the Plural helper's
/// CLDR category selection. A wrong or missing key falls back to the key
/// text, so the exact-value assertions catch regressions.
final class LocalizationTests: XCTestCase {
    /// The built app bundle if present, else the source Resources directory
    /// (both carry the same .lproj contents; the test target runs from the
    /// repo root).
    private var bundle: Bundle {
        for candidate in ["SplashMenuBar.app", "Resources"] {
            if let b = Bundle(path: candidate),
               b.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil {
                return b
            }
        }
        XCTFail("no .lproj found — build the app or run from the repo root")
        return Bundle.main
    }

    func testSimpleKey() {
        XCTAssertEqual(String(localized: "Model cache", bundle: bundle), "Model cache")
        XCTAssertEqual(String(localized: "Stop", bundle: bundle), "Stop")
    }

    func testInterpolatedKey() {
        let id = "abc123"
        let repo = "incoai/splash"
        XCTAssertEqual(String(localized: "Remove version \(id) of \(repo)?", bundle: bundle),
                       "Remove version abc123 of incoai/splash?")
    }

    func testPluralFiles() {
        XCTAssertEqual(Plural.format("files", 1, bundle: bundle), "1 file")
        XCTAssertEqual(Plural.format("files", 5, bundle: bundle), "5 files")
    }

    func testPluralVersions() {
        XCTAssertEqual(Plural.format("versions", 1, bundle: bundle), "1 version")
        XCTAssertEqual(Plural.format("versions", 3, bundle: bundle), "3 versions")
    }

    func testPluralEngineFailures() {
        XCTAssertEqual(Plural.format("engineFailures", 1, bundle: bundle),
                       " 1 engine failure since startup.")
        XCTAssertEqual(Plural.format("engineFailures", 2, bundle: bundle),
                       " 2 engine failures since startup.")
    }

    func testPluralRemoveVersions() {
        XCTAssertEqual(Plural.format("removeVersions", 1, ["3.2 GiB"], bundle: bundle),
                       "Removes all 1 version, freeing about 3.2 GiB. This only affects local files; splash can re-download them.")
        XCTAssertEqual(Plural.format("removeVersions", 2, ["3.2 GiB"], bundle: bundle),
                       "Removes all 2 versions, freeing about 3.2 GiB. This only affects local files; splash can re-download them.")
    }

    func testPluralFallsBackToOther() {
        XCTAssertEqual(Plural.format("files", 0, bundle: bundle), "0 files")
    }

    func testPluralMissingBaseFallsBackToKey() {
        // Unknown base: returns the .other key text verbatim (no crash).
        XCTAssertEqual(Plural.format("nope", 2, bundle: bundle), "nope.other")
    }

    func testCategoryRules() {
        XCTAssertEqual(Plural.category(1, locale: Locale(identifier: "en_US")), "one")
        XCTAssertEqual(Plural.category(2, locale: Locale(identifier: "en_US")), "other")
        XCTAssertEqual(Plural.category(1, locale: Locale(identifier: "ru_RU")), "one")
        XCTAssertEqual(Plural.category(3, locale: Locale(identifier: "ru_RU")), "few")
        XCTAssertEqual(Plural.category(5, locale: Locale(identifier: "ru_RU")), "many")
        XCTAssertEqual(Plural.category(21, locale: Locale(identifier: "ru_RU")), "one")
        XCTAssertEqual(Plural.category(0, locale: Locale(identifier: "fr_FR")), "one")
        XCTAssertEqual(Plural.category(2, locale: Locale(identifier: "fr_FR")), "other")
        XCTAssertEqual(Plural.category(2, locale: Locale(identifier: "ja_JP")), "other")
        XCTAssertEqual(Plural.category(2, locale: Locale(identifier: "zh_CN")), "other")
    }
}
