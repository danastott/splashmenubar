import XCTest
@testable import SplashMenuBar

final class SettingsModelTests: XCTestCase {
    /// One instance per test class run is enough: the validation under test
    /// only reads the port/model fields, and each init kicks a background
    /// Hugging Face cache scan we don't want to repeat per assertion.
    private lazy var settings: SettingsModel = {
        let m = SettingsModel(config: .default)
        m.model = "owner/repo:V"
        m.customModel = false
        return m
    }()

    func testPortValidation() {
        for good in ["8081", " 1234 ", "1", "65535"] {
            settings.port = good
            XCTAssertNil(settings.portError, "expected no error for port \(good)")
        }
        for bad in ["0", "65536", "99999", "abc", "12 34", ""] {
            settings.port = bad
            XCTAssertNotNil(settings.portError, "expected an error for port \(bad)")
            XCTAssertFalse(settings.isValid, "Save must be blocked for port \(bad)")
        }
    }

    func testModelValidation() {
        settings.port = "8081"
        settings.model = "owner/repo"
        XCTAssertNil(settings.modelError)
        XCTAssertTrue(settings.isValid)
        for bad in ["", "   "] {
            settings.model = bad
            XCTAssertNotNil(settings.modelError, "expected an error for model \(bad)")
            XCTAssertFalse(settings.isValid, "Save must be blocked for model \(bad)")
        }
    }

    func testAsConfigUsesTypedValues() {
        settings.port = "9000"
        settings.model = "owner/repo:V"
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.asConfig.port, 9000)
        XCTAssertEqual(settings.asConfig.model, "owner/repo:V")
    }

    func testWhitespaceIsTrimmed() {
        settings.port = " 9000 "
        settings.model = "  owner/repo:V  "
        XCTAssertNil(settings.portError)
        XCTAssertNil(settings.modelError)
        XCTAssertEqual(settings.asConfig.port, 9000)
        XCTAssertEqual(settings.asConfig.model, "owner/repo:V")
    }
}
