import XCTest
@testable import OloKit

final class SpeechPiecesTests: XCTestCase {
    func testProseNotMarkdown() {
        XCTAssertEqual(SpeechPieces.plain("## Title\n\n**The wall fell** in 1989 [1].\n\n```js\nx()\n```"), "Title. The wall fell in 1989. Code omitted.")
    }

    func testShortFirstPieceAndNoCutInsideAWord() {
        let sentences = (0..<40).map { "Sentence number \($0) says something worth hearing about the matter at hand." }
        let pieces = SpeechPieces.split(sentences.joined(separator: " "))
        XCTAssertGreaterThan(pieces.count, 3)
        XCTAssertLessThanOrEqual(pieces[0].count, SpeechPieces.firstPieceChars)
        XCTAssertTrue(pieces[0].hasSuffix("."))
        for p in pieces { XCTAssertLessThanOrEqual(p.count, SpeechPieces.pieceChars) }
        XCTAssertEqual(pieces.joined(separator: " "), sentences.joined(separator: " "))
    }

    func testOneLongSentenceIsCutAtCommas() {
        let long = (0..<200).map { "item\($0)" }.joined(separator: ", ")
        let pieces = SpeechPieces.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        for p in pieces {
            XCTAssertLessThanOrEqual(p.count, SpeechPieces.pieceChars)
            XCTAssertTrue(p.hasPrefix("item"))
        }
        XCTAssertEqual(pieces.joined(separator: " "), long)
    }

    func testEmpty() {
        XCTAssertEqual(SpeechPieces.split("   "), [])
        XCTAssertEqual(SpeechPieces.split("```js\n```"), ["Code omitted."])
    }
}
