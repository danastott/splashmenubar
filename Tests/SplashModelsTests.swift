import XCTest
@testable import SplashMenuBar

final class SplashModelsTests: XCTestCase {
    func testGgufVariantSingleFile() {
        XCTAssertEqual(SplashModels.ggufVariant("Qwen3.8-27B-UD-Q4_K_M.gguf"), "UD-Q4_K_M")
        XCTAssertEqual(SplashModels.ggufVariant("Flint-Q2_0.gguf"), "Q2_0")
        XCTAssertEqual(SplashModels.ggufVariant("Ternary-Bonsai-2-27B-PQ2_0.gguf"), "PQ2_0")
    }

    func testGgufVariantSplitFolder() {
        // Split files live in one folder named after the quant.
        XCTAssertEqual(
            SplashModels.ggufVariant("UD-Q4_K_XL/model-00001-of-00003.gguf"), "UD-Q4_K_XL")
    }

    func testGgufVariantNoneForMmprojOrPlain() {
        XCTAssertNil(SplashModels.ggufVariant("mmproj-Qwen3.8-27B-UD-Q4_K_M.gguf"))
        XCTAssertNil(SplashModels.ggufVariant("model.gguf"))
    }

    func testSplitComplete() {
        XCTAssertTrue(SplashModels.splitComplete([]))
        XCTAssertTrue(SplashModels.splitComplete(["a.gguf"]))
        XCTAssertTrue(SplashModels.splitComplete([
            "m/model-00001-of-00003.gguf",
            "m/model-00002-of-00003.gguf",
            "m/model-00003-of-00003.gguf",
        ]))
        // Missing part 2 of 3.
        XCTAssertFalse(SplashModels.splitComplete([
            "m/model-00001-of-00003.gguf",
            "m/model-00003-of-00003.gguf",
        ]))
    }

    func testParseModelId() {
        let (repo, variant) = SplashModels.parse("owner/repo:UD-Q4_K_M")
        XCTAssertEqual(repo, "owner/repo")
        XCTAssertEqual(variant, "UD-Q4_K_M")
        let plain = SplashModels.parse("owner/repo")
        XCTAssertEqual(plain.repo, "owner/repo")
        XCTAssertNil(plain.variant)
    }
}
