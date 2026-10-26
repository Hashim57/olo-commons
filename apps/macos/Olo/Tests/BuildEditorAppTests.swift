import XCTest
@testable import Olo

/// Build with Olo's editor: names for new files stay inside the folder, and only text opens.
final class BuildEditorAppTests: XCTestCase {
    func testNewFileNamesStayInsideTheFolder() {
        XCTAssertEqual(BuildEditor.cleanRelativePath(" src//main.swift "), "src/main.swift")
        XCTAssertEqual(BuildEditor.cleanRelativePath("notes.md"), "notes.md")
        XCTAssertNil(BuildEditor.cleanRelativePath("/etc/hosts"))
        XCTAssertNil(BuildEditor.cleanRelativePath("../outside.txt"))
        XCTAssertNil(BuildEditor.cleanRelativePath("a/./b"))
        XCTAssertNil(BuildEditor.cleanRelativePath("~/x"))
        XCTAssertNil(BuildEditor.cleanRelativePath("   "))
    }

    func testOnlyTextOpens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(BuildEditor.readText(text), "let x = 1\n")
        let binary = dir.appendingPathComponent("b.bin")
        try Data([0x01, 0x00, 0x02]).write(to: binary)
        XCTAssertNil(BuildEditor.readText(binary))
        XCTAssertNil(BuildEditor.readText(dir.appendingPathComponent("missing.txt")))
    }
}
