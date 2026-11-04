import XCTest
@testable import SplashMenuBar

/// The pipe reader only decodes bytes at line boundaries; these tests pin
/// the split semantics, including that a multibyte UTF-8 character cut
/// across two pipe chunks is always reassembled before it is decoded.
final class OutputReaderTests: XCTestCase {
    /// Feeds bytes chunk by chunk the way the pipe does, keeping the
    /// unread tail, and returns the decoded lines (plus the unterminated
    /// tail at the end, as the reader delivers it on EOF).
    private func lines(from chunks: [Data]) -> [String] {
        var pending = Data()
        var out: [String] = []
        for chunk in chunks {
            pending.append(chunk)
            let split = OutputReader.splitLines(pending)
            pending = split.rest
            for line in split.lines {
                out.append(String(decoding: line, as: UTF8.self))
            }
        }
        if !pending.isEmpty { out.append(String(decoding: pending, as: UTF8.self)) }
        return out
    }

    /// A tqdm-style bar with a 3-byte block glyph, cut at every possible
    /// byte position — the reassembled lines must be identical each time.
    func testMultibyteCharacterSurvivesEveryChunkBoundary() {
        let s = "download \u{258A} 42%\rnext \u{258A} 45%\r"
        let data = s.data(using: .utf8)!
        for i in 1..<data.count {
            let out = lines(from: [Data(data.prefix(i)), Data(data.dropFirst(i))])
            XCTAssertEqual(out, ["download \u{258A} 42%", "next \u{258A} 45%"],
                           "chunk boundary at byte \(i)")
        }
    }

    func testCRActsAsLineEnd() {
        XCTAssertEqual(lines(from: [Data("bar 1\rbar 2\r".utf8)]), ["bar 1", "bar 2"])
    }

    func testUnterminatedTailIsKeptForNextChunk() {
        let split = OutputReader.splitLines(Data("x\ry".utf8))
        XCTAssertEqual(split.lines.map { String(decoding: $0, as: UTF8.self) }, ["x"])
        XCTAssertEqual(split.rest.map { $0 }, [0x79])
    }

    func testEmptyInput() {
        let split = OutputReader.splitLines(Data())
        XCTAssertTrue(split.lines.isEmpty)
        XCTAssertTrue(split.rest.isEmpty)
    }
}
