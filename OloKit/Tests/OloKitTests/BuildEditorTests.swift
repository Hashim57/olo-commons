import XCTest
@testable import OloKit

/// Build with Olo v2: the line diff, keeping issues on their lines, indentation, the tokeniser,
/// completion clean up and the new requests.
final class LineDiffTests: XCTestCase {
    func testIdenticalLinesAreAllSame() {
        let ops = LineDiff.ops(["a", "b"], ["a", "b"])
        XCTAssertEqual(ops, [.same(0, 0), .same(1, 1)])
        XCTAssertTrue(LineDiff.rows(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    func testReplacementInTheMiddle() {
        let ops = LineDiff.ops(["a", "b", "c"], ["a", "x", "c"])
        XCTAssertEqual(ops, [.same(0, 0), .removed(1), .added(1), .same(2, 2)])
    }

    func testInsertionAndDeletion() {
        XCTAssertEqual(LineDiff.ops(["a", "c"], ["a", "b", "c"]), [.same(0, 0), .added(1), .same(1, 2)])
        XCTAssertEqual(LineDiff.ops(["a", "b", "c"], ["a", "c"]), [.same(0, 0), .removed(1), .same(2, 1)])
        XCTAssertEqual(LineDiff.ops([], ["a"]), [.added(0)])
        XCTAssertEqual(LineDiff.ops(["a"], []), [.removed(0)])
    }

    func testLongestCommonSubsequenceInTheMiddle() {
        let old = ["start", "a", "b", "c", "d", "end"]
        let new = ["start", "b", "x", "d", "y", "end"]
        let ops = LineDiff.ops(old, new)
        let same = ops.compactMap { op -> String? in
            if case .same(let o, _) = op { return old[o] }
            return nil
        }
        XCTAssertEqual(same, ["start", "b", "d", "end"])
        // Every line accounted for exactly once.
        XCTAssertEqual(ops.filter { if case .added = $0 { return false }; return true }.count, old.count)
        XCTAssertEqual(ops.filter { if case .removed = $0 { return false }; return true }.count, new.count)
    }

    func testLineMap() {
        let map = LineDiff.lineMap(["a", "b", "c"], ["new", "a", "B", "c"])
        XCTAssertEqual(map, [1, nil, 3])
    }

    func testRowsFoldLongUnchangedRuns() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[9] = "changed"
        let rows = LineDiff.rows(old: old, new: new, context: 2)
        XCTAssertEqual(rows.first?.kind, .skipped)
        XCTAssertEqual(rows.first?.skipped, 7)
        XCTAssertEqual(rows.last?.kind, .skipped)
        XCTAssertEqual(rows.last?.skipped, 8)
        XCTAssertEqual(rows.filter { $0.kind == .removed }.map(\.text), ["line 10"])
        XCTAssertEqual(rows.filter { $0.kind == .added }.map(\.newLine), [10])
        XCTAssertEqual(LineDiff.counts(rows).added, 1)
        XCTAssertEqual(LineDiff.counts(rows).removed, 1)
        XCTAssertEqual(rows.map(\.id), Array(0..<rows.count))
    }

    func testLargeRewritesStillDiff() {
        let old = (0..<3000).map { "old \($0)" }
        let new = (0..<3000).map { "new \($0)" }
        let ops = LineDiff.ops(old, new)
        XCTAssertEqual(ops.count, 6000)
    }
}

final class IssueRebaserTests: XCTestCase {
    private let text = "one\ntwo\nthree\nfour\n"

    func testLinesInsertedAboveMoveTheIssueAndItsFix() {
        let issue = CodeIssue(id: "i", line: 3, severity: "error", category: "bug", message: "m",
                              fix: CodeFix(startLine: 3, endLine: 4, replacement: "x"))
        let out = IssueRebaser.rebase([issue], from: text, to: "zero\nhalf\none\ntwo\nthree\nfour\n")
        XCTAssertEqual(out.first?.line, 5)
        XCTAssertEqual(out.first?.fix, CodeFix(startLine: 5, endLine: 6, replacement: "x"))
    }

    func testEditingTheIssueLineDropsIt() {
        let issue = CodeIssue(id: "i", line: 2, severity: "warning", category: "bug", message: "m")
        XCTAssertTrue(IssueRebaser.rebase([issue], from: text, to: "one\ntwo!\nthree\nfour\n").isEmpty)
    }

    func testEditingAFixLineKeepsTheIssueWithoutTheFix() {
        let issue = CodeIssue(id: "i", line: 1, severity: "error", category: "security", message: "m",
                              fix: CodeFix(startLine: 2, endLine: 3, replacement: "y"))
        let out = IssueRebaser.rebase([issue], from: text, to: "one\ntwo\nTHREE\nfour\n")
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out.first?.fix)
    }

    func testInsertionFixFollowsItsLine() {
        let issue = CodeIssue(id: "i", line: 2, severity: "info", category: "style", message: "m",
                              fix: CodeFix(startLine: 2, endLine: 1, replacement: "// note"))
        let out = IssueRebaser.rebase([issue], from: text, to: "new\none\ntwo\nthree\nfour\n")
        XCTAssertEqual(out.first?.fix, CodeFix(startLine: 3, endLine: 2, replacement: "// note"))
    }

    func testUnchangedTextKeepsEverything() {
        let issue = CodeIssue(id: "i", line: 2, severity: "info", category: "style", message: "m")
        XCTAssertEqual(IssueRebaser.rebase([issue], from: text, to: text), [issue])
    }
}

final class CodeIndentTests: XCTestCase {
    func testUnitByLanguage() {
        XCTAssertEqual(CodeIndent.unit(for: "src/app.ts"), "  ")
        XCTAssertEqual(CodeIndent.unit(for: "config.yaml"), "  ")
        XCTAssertEqual(CodeIndent.unit(for: "main.swift"), "    ")
        XCTAssertEqual(CodeIndent.unit(for: "tool.py"), "    ")
    }

    func testNewLineCopiesIndentation() {
        let r = CodeIndent.newline(before: "    let x = 1", after: "", unit: "    ")
        XCTAssertEqual(r.text, "\n    ")
        XCTAssertEqual(r.caret, 5)
    }

    func testNewLineIndentsAfterOpeners() {
        XCTAssertEqual(CodeIndent.newline(before: "def f(x):", after: "", unit: "    ").text, "\n    ")
        XCTAssertEqual(CodeIndent.newline(before: "  items = [", after: "", unit: "  ").text, "\n    ")
        XCTAssertEqual(CodeIndent.newline(before: "\tif (a) {  ", after: "", unit: "    ").text, "\n\t    ")
    }

    func testNewLineBetweenBracketsPutsTheCloserOnItsOwnLine() {
        let r = CodeIndent.newline(before: "  func f() {", after: "}", unit: "  ")
        XCTAssertEqual(r.text, "\n    \n  ")
        XCTAssertEqual(r.caret, 5)
    }

    func testOutdent() {
        XCTAssertEqual(CodeIndent.outdented("      x", unit: "    "), "  x")
        XCTAssertEqual(CodeIndent.outdented("\t\tx", unit: "    "), "\tx")
        XCTAssertEqual(CodeIndent.outdented(" x", unit: "    "), "x")
    }
}

final class SyntaxScannerTests: XCTestCase {
    private func found(_ text: String, _ language: String) -> [String] {
        let ns = text as NSString
        return SyntaxScanner.tokens(in: text, language: language).map { "\($0.kind.rawValue):\(ns.substring(with: $0.range))" }
    }

    func testSwiftStringsHideCommentsAndKeywords() {
        XCTAssertEqual(found(#"let s = "if // no" // note"#, "swift"),
                       ["keyword:let", #"string:"if // no""#, "comment:// note"])
    }

    func testPythonCommentsNumbersAndKeywords() {
        XCTAssertEqual(found("def f(x): # hi\n    return 0x1F", "python"),
                       ["keyword:def", "comment:# hi", "keyword:return", "number:0x1F"])
    }

    func testBlockCommentsAndIdentifiersWithDigits() {
        XCTAssertEqual(found("/* a\nb */ var x1 = 2.5", "javascript"),
                       ["comment:/* a\nb */", "keyword:var", "number:2.5"])
    }

    func testSQLIsCaseInsensitive() {
        XCTAssertEqual(found("SELECT 1 -- c", "sql"), ["keyword:SELECT", "number:1", "comment:-- c"])
    }

    func testFamilies() {
        XCTAssertEqual(SyntaxFamily.of(language: "typescript"), .cLike)
        XCTAssertEqual(SyntaxFamily.of(language: "rust"), .cLikeStrictQuotes)
        XCTAssertEqual(SyntaxFamily.of(language: "yaml"), .hash)
        XCTAssertEqual(SyntaxFamily.of(language: "text"), .plain)
        XCTAssertTrue(SyntaxScanner.tokens(in: "if 1", language: "text").isEmpty)
        // Every family's expression compiles.
        for f in SyntaxFamily.allCases where f != .plain {
            XCTAssertNotNil(SyntaxScanner.compiled[f], f.rawValue)
        }
    }

    func testUTF16Ranges() {
        let text = "let e = \"\u{1F600}\" // ok"
        XCTAssertEqual(found(text, "swift"), ["keyword:let", "string:\"\u{1F600}\"", "comment:// ok"])
    }
}

final class CompletionCleanupTests: XCTestCase {
    func testStripsFences() {
        XCTAssertEqual(CompletionCleanup.clean("```swift\nreturn x\n```", prefix: "func f() {\n    ", suffix: "\n}"), "return x")
    }

    func testDropsTheRepeatedLine() {
        XCTAssertEqual(CompletionCleanup.clean("let total = a + b", prefix: "    let total = ", suffix: "\n"), "a + b")
        XCTAssertEqual(CompletionCleanup.clean("    return 1", prefix: "{\n    ", suffix: ""), "return 1")
    }

    func testDropsLinesThatAlreadyFollow() {
        let out = CompletionCleanup.clean("\n    return a\n}", prefix: "func f() {", suffix: "\n}\n\nfunc g() {}")
        XCTAssertEqual(out, "\n    return a")
    }

    func testDropsTheRestOfTheLine() {
        XCTAssertEqual(CompletionCleanup.clean("a, b)", prefix: "call(", suffix: ")\nnext"), "a, b")
    }

    func testWhitespaceOnlyIsEmpty() {
        XCTAssertEqual(CompletionCleanup.clean("  \n\n ", prefix: "x", suffix: ""), "")
    }

    func testAtMostThirtyLines() {
        let long = (1...50).map { "line\($0)" }.joined(separator: "\n")
        XCTAssertEqual(CompletionCleanup.clean(long, prefix: "", suffix: "").components(separatedBy: "\n").count, 30)
    }
}

final class CodeAssistRequestTests: XCTestCase {
    func testEditInputTrimsAndOmitsAMissingSelection() throws {
        let input = CodeEditInput(path: "src/app.ts", content: "let a = 1", instruction: "  add a test  ")
        XCTAssertEqual(input.language, "typescript")
        XCTAssertEqual(input.instruction, "add a test")
        let body = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        XCTAssertFalse(body.contains("selection"))
        let withSelection = CodeEditInput(path: "a.py", content: "x", instruction: "y", selection: CodeEditSelection(startLine: 4, endLine: 2))
        XCTAssertEqual(withSelection.selection, CodeEditSelection(startLine: 4, endLine: 4))
        XCTAssertFalse(CodeEditInput.fits(String(repeating: "x", count: CodeReviewInput.maxContent + 1)))
    }

    func testEditRequestShape() throws {
        let req = try TRPC.mutationRequest(base: URL(string: "https://helius-olo.io")!, path: "code.edit",
                                           input: CodeEditInput(path: "a.swift", content: "", instruction: "write hello"), token: "t")
        XCTAssertEqual(req.url?.path, "/api/trpc/code.edit")
        let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        let inner = json?["json"] as? [String: Any]
        XCTAssertEqual(inner?["instruction"] as? String, "write hello")
        XCTAssertEqual(inner?["language"] as? String, "swift")
    }

    func testCompleteInputKeepsTheTextNearestTheCursor() {
        let prefix = String(repeating: "a", count: 9_000) + "END"
        let suffix = "START" + String(repeating: "b", count: 5_000)
        let input = CodeCompleteInput(path: "x.go", prefix: prefix, suffix: suffix)
        XCTAssertEqual(input.prefix.count, CodeCompleteInput.maxPrefix)
        XCTAssertTrue(input.prefix.hasSuffix("END"))
        XCTAssertEqual(input.suffix.count, CodeCompleteInput.maxSuffix)
        XCTAssertTrue(input.suffix.hasPrefix("START"))
        XCTAssertEqual(input.language, "go")
    }

    func testResultsDecodeTolerantly() throws {
        let edit = Data(#"{"result":{"data":{"json":{"content":"print(1)\n"}}}}"#.utf8)
        let e = try TRPC.decode(CodeEditResult.self, data: edit, status: 200)
        XCTAssertEqual(e.content, "print(1)\n")
        XCTAssertEqual(e.explanation, "")
        let complete = Data(#"{"result":{"data":{"json":{"model":"fast"}}}}"#.utf8)
        XCTAssertEqual(try TRPC.decode(CodeCompleteResult.self, data: complete, status: 200).completion, "")
    }

    func testAllowanceExhaustedAndMissingProcedure() {
        let body = Data(#"{"error":{"json":{"message":"Build with Olo allowance used for today","data":{"code":"TOO_MANY_REQUESTS"}}}}"#.utf8)
        XCTAssertThrowsError(try TRPC.decode(CodeEditResult.self, data: body, status: 429)) { e in
            let remote = e as? TRPC.RemoteError
            XCTAssertEqual(remote?.isAllowanceExhausted, true)
            XCTAssertEqual(remote?.message, "Build with Olo allowance used for today")
        }
        let missing = Data(#"{"error":{"json":{"message":"No procedure","data":{"code":"NOT_FOUND"}}}}"#.utf8)
        XCTAssertThrowsError(try TRPC.decode(CodeCompleteResult.self, data: missing, status: 404)) { e in
            XCTAssertEqual((e as? TRPC.RemoteError)?.isNotFound, true)
        }
    }

    func testAllowanceShapes() throws {
        let nested = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"reviews":{"used":12,"limit":60},"completions":{"remaining":280,"limit":300}}"#.utf8))
        let a = BuildAllowance.read(nested)
        XCTAssertEqual(a, BuildAllowance(used: 12, limit: 60, completionsUsed: 20, completionsLimit: 300))
        XCTAssertEqual(a?.summary, "Build: 48 of 60 reviews and edits left today, 280 of 300 suggestions")
        let flat = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"used":1,"limit":60}"#.utf8))
        XCTAssertEqual(BuildAllowance.read(flat)?.limit, 60)
        let none = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(BuildAllowance.read(none))
    }
}
