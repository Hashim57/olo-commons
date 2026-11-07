import XCTest
import AppKit
@testable import Olo

final class FileExtractorTests: XCTestCase {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
    }

    func testReadsPlainText() throws {
        let u = temp("notes.md")
        try "# Title\nOlo reads markdown.".write(to: u, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileExtractor.text(of: u), "# Title\nOlo reads markdown.")
        XCTAssertEqual(FileExtractor.attachment(for: u)?.kind, .file)
    }

    func testReadsRTFThroughTheSystemImporter() throws {
        let u = temp("letter.rtf")
        let rtf = NSAttributedString(string: "Hello from a rich text file.")
        let data = try rtf.data(from: NSRange(location: 0, length: rtf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: u)
        XCTAssertEqual(FileExtractor.text(of: u)?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello from a rich text file.")
    }

    func testStripsHTML() {
        let s = FileExtractor.stripTags("<html><style>p{}</style><script>x()</script><p>Fish &amp; chips</p></html>")
        XCTAssertEqual(s.trimmingCharacters(in: .whitespaces), "Fish & chips")
    }

    func testRefusesUnknownBinary() throws {
        let u = temp("image.heic")
        try Data([0, 1, 2, 3]).write(to: u)
        XCTAssertFalse(FileExtractor.canRead(u))
        XCTAssertNil(FileExtractor.text(of: u))
    }
}
