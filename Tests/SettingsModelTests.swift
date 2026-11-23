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

    /// The splash 1.7.x settings fields carry through form → config: the
    /// typed values when set, and nil when at the default (the form's
    /// "auto (default)" / "int8 (default)" picks pass no flag).
    func testNewFlagFieldsRoundTrip() {
        var c = SplashConfig.default
        c.maxConcurrentRequests = 6
        c.samplingDefaults = "top_k=4096"
        c.activations = "bf16"
        c.verifyRows = "all"
        c.cachedStates = "exact"
        c.recalibrateANE = true
        let m = SettingsModel(config: c)
        XCTAssertEqual(m.maxConcurrentRequests, 6)
        XCTAssertEqual(m.samplingDefaults, "top_k=4096")
        XCTAssertEqual(m.activations, "bf16")
        XCTAssertEqual(m.verifyRows, "all")
        XCTAssertEqual(m.cachedStates, "exact")
        XCTAssertTrue(m.recalibrateANE)
        let out = m.asConfig
        XCTAssertEqual(out.maxConcurrentRequests, 6)
        XCTAssertEqual(out.samplingDefaults, "top_k=4096")
        XCTAssertEqual(out.activations, "bf16")
        XCTAssertEqual(out.verifyRows, "all")
        XCTAssertEqual(out.cachedStates, "exact")
        XCTAssertTrue(out.recalibrateANE)
    }

    func testNewFlagFieldsDefaultsNormalizeToNil() {
        let m = SettingsModel(config: SplashConfig.default)
        XCTAssertNil(m.maxConcurrentRequests)
        XCTAssertEqual(m.activations, "auto")
        XCTAssertEqual(m.verifyRows, "auto")
        XCTAssertEqual(m.cachedStates, "int8")
        XCTAssertFalse(m.recalibrateANE)
        let out = m.asConfig
        XCTAssertNil(out.maxConcurrentRequests)
        XCTAssertNil(out.samplingDefaults)
        XCTAssertNil(out.activations)
        XCTAssertNil(out.verifyRows)
        XCTAssertNil(out.cachedStates)
        XCTAssertFalse(out.recalibrateANE)
        // Reset lands on the same defaults.
        m.maxConcurrentRequests = 2
        m.samplingDefaults = "temperature=1"
        m.activations = "bf16"
        m.verifyRows = "all"
        m.cachedStates = "exact"
        m.recalibrateANE = true
        m.resetToDefaults()
        let reset = m.asConfig
        XCTAssertNil(reset.maxConcurrentRequests)
        XCTAssertNil(reset.samplingDefaults)
        XCTAssertNil(reset.activations)
        XCTAssertNil(reset.verifyRows)
        XCTAssertNil(reset.cachedStates)
        XCTAssertFalse(reset.recalibrateANE)
    }

    /// --sampling-default accepts only the server's seven sampling fields
    /// with a numeric value; anything else blocks Save.
    func testSamplingDefaultsValidation() {
        for good in ["", "  ", "temperature=0.7",
                     "temperature=0.7 top_p=0.9",
                     "top_k=4096 min_p=0.1",
                     "repetition_penalty=1.05"] {
            settings.samplingDefaults = good
            XCTAssertNil(settings.samplingDefaultsError,
                         "expected no error for \(good.debugDescription)")
            settings.port = "8081"
            settings.model = "owner/repo"
            XCTAssertTrue(settings.isValid, "Save must pass for \(good.debugDescription)")
        }
        for bad in ["temperature", "temperature=", "temperature=fast",
                    "speed=1", "top_k", "=1"] {
            settings.samplingDefaults = bad
            XCTAssertNotNil(settings.samplingDefaultsError,
                            "expected an error for \(bad.debugDescription)")
            XCTAssertFalse(settings.isValid, "Save must be blocked for \(bad.debugDescription)")
        }
    }
}
