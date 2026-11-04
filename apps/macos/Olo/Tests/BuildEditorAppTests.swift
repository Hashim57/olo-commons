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

    /// The three columns are planned from the width that is really there, so nothing is ever clipped.
    func testBuildColumnsFitTheWidthTheyHave() {
        // Wide: every column at its ideal width.
        let wide = BuildColumns.plan(width: 1400, showFiles: true, showOloPane: true)
        XCTAssertEqual(wide.files, BuildColumns.filesWidth)
        XCTAssertEqual(wide.olo, BuildColumns.oloWidth)
        // The narrowest window (1100 less the sidebar) still shows all three, shrunk.
        let fits = BuildColumns.plan(width: 820, showFiles: true, showOloPane: true)
        XCTAssertNotNil(fits.files); XCTAssertNotNil(fits.olo)
        XCTAssertGreaterThanOrEqual(820 - (fits.files ?? 0) - (fits.olo ?? 0), BuildColumns.editorMin)
        // Narrower still: the Olo pane goes first, then the file list; the editor always keeps its minimum.
        let noOlo = BuildColumns.plan(width: 700, showFiles: true, showOloPane: true)
        XCTAssertNil(noOlo.olo); XCTAssertNotNil(noOlo.files)
        let onlyEditor = BuildColumns.plan(width: 500, showFiles: true, showOloPane: true)
        XCTAssertNil(onlyEditor.olo); XCTAssertNil(onlyEditor.files)
        // Hidden columns are not planned at all.
        let hidden = BuildColumns.plan(width: 1400, showFiles: false, showOloPane: false)
        XCTAssertNil(hidden.files); XCTAssertNil(hidden.olo)
    }
}
