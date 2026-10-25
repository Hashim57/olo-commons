import CryptoKit
import XCTest
@testable import OloKit

/// Build with Olo: applying fixes as pure functions on lines.
final class CodeReviewTests: XCTestCase {
    private let five = ["one", "two", "three", "four", "five"]

    func testSingleLineFix() {
        let out = FixApplier.apply(CodeFix(startLine: 2, endLine: 2, replacement: "TWO"), to: five)
        XCTAssertEqual(out, ["one", "TWO", "three", "four", "five"])
    }

    func testMultiLineFixReplacesARangeWithMoreLines() {
        let out = FixApplier.apply(CodeFix(startLine: 2, endLine: 3, replacement: "a\nb\nc\n"), to: five)
        XCTAssertEqual(out, ["one", "a", "b", "c", "four", "five"])
    }

    func testEmptyReplacementDeletesTheLines() {
        let out = FixApplier.apply(CodeFix(startLine: 3, endLine: 4, replacement: ""), to: five)
        XCTAssertEqual(out, ["one", "two", "five"])
    }

    func testInsertionAtTheEnd() {
        let out = FixApplier.apply(CodeFix(startLine: 6, endLine: 6, replacement: "six"), to: five)
        XCTAssertEqual(out, ["one", "two", "three", "four", "five", "six"])
        let before = FixApplier.apply(CodeFix(startLine: 3, endLine: 2, replacement: "inserted"), to: five)
        XCTAssertEqual(before, ["one", "two", "inserted", "three", "four", "five"])
    }

    func testOverlappingFixesAreRejected() {
        let a = CodeFix(startLine: 2, endLine: 3, replacement: "x")
        let b = CodeFix(startLine: 3, endLine: 4, replacement: "y")
        XCTAssertThrowsError(try FixApplier.applyAll([a, b], to: five)) { e in
            XCTAssertEqual(e as? FixApplier.Failure, .overlapping)
        }
        XCTAssertEqual(FixApplier.nonOverlapping([b, a], count: five.count), [a])
    }

    func testSeparateFixesApplyTogetherAgainstTheOriginalLines() throws {
        let a = CodeFix(startLine: 1, endLine: 1, replacement: "ONE\nONE AND A HALF")
        let b = CodeFix(startLine: 4, endLine: 5, replacement: "")
        let out = try FixApplier.applyAll([a, b], to: five)
        XCTAssertEqual(out, ["ONE", "ONE AND A HALF", "two", "three"])
    }

    func testOutOfRangeLinesAreClamped() {
        let out = FixApplier.apply(CodeFix(startLine: 0, endLine: 99, replacement: "all"), to: five)
        XCTAssertEqual(out, ["all"])
        let past = FixApplier.apply(CodeFix(startLine: 40, endLine: 50, replacement: "tail"), to: five)
        XCTAssertEqual(past, five + ["tail"])
        XCTAssertEqual(FixApplier.apply(CodeFix(startLine: 1, endLine: 1, replacement: "first"), to: []), ["first"])
    }

    func testRebaseMovesIssuesBelowAndDropsTouchedOnes() {
        let fix = CodeFix(startLine: 2, endLine: 2, replacement: "a\nb\nc")
        let issues = [
            CodeIssue(id: "above", line: 1, severity: "info", category: "style", message: "m"),
            CodeIssue(id: "same", line: 2, severity: "error", category: "bug", message: "m"),
            CodeIssue(id: "below", line: 4, severity: "warning", category: "bug", message: "m", fix: CodeFix(startLine: 4, endLine: 4, replacement: "z")),
        ]
        let out = FixApplier.rebase(issues, after: fix, count: 5)
        XCTAssertEqual(out.map(\.id), ["above", "below"])
        XCTAssertEqual(out[1].line, 6)
        XCTAssertEqual(out[1].fix?.startLine, 6)
    }

    func testSourceTextKeepsLineEndingsAndTheLastNewline() {
        let crlf = SourceText("a\r\nb\r\n")
        XCTAssertEqual(crlf.lines, ["a", "b"])
        XCTAssertEqual(crlf.text, "a\r\nb\r\n")
        let bare = SourceText("x\ny")
        XCTAssertFalse(bare.trailingNewline)
        XCTAssertEqual(bare.text, "x\ny")
        XCTAssertEqual(SourceText("").lines, [])
    }

    func testReviewDecodesTolerantly() throws {
        let data = Data(#"{"result":{"data":{"json":{"issues":[{"id":"i1","line":3,"endLine":4,"severity":"error","category":"security","message":"SQL built from input","fix":{"startLine":3,"endLine":4,"replacement":"db.query(sql, [id])"}},{"line":9,"severity":"loud","category":"style","message":"Trailing space","fix":null}],"summary":"One injection risk.","model":"claude"}}}}"#.utf8)
        let r = try TRPC.decode(CodeReviewResult.self, data: data, status: 200)
        XCTAssertEqual(r.issues.count, 2)
        XCTAssertTrue(r.issues[0].autoFixable)
        XCTAssertFalse(r.issues[0].isSafe)
        XCTAssertEqual(r.issues[1].severity, "info")
        XCTAssertEqual(r.issues[1].endLine, 9)
        XCTAssertNil(r.issues[1].fix)
        XCTAssertFalse(r.issues[1].id.isEmpty)
        XCTAssertEqual(r.summary, "One injection risk.")
    }

    func testReviewInputTrimsToTheServerLimits() throws {
        let big = String(repeating: "a", count: 70_000)
        let input = CodeReviewInput(path: "src/app.ts", content: big, previous: big)
        XCTAssertEqual(input.language, "typescript")
        XCTAssertEqual(input.content.count, 60_000)
        XCTAssertNil(input.previous)
        let body = String(decoding: try JSONEncoder().encode(CodeReviewInput(path: "a.swift", content: "let x = 1", previous: "let x = 0")), as: UTF8.self)
        XCTAssertTrue(body.contains(#""previous":"let x = 0""#))
        XCTAssertFalse(body.contains("focus"))
    }

    func testIgnoreListSkipsDependenciesBuildOutputAndGitignorePatterns() {
        let ignore = ReviewIgnore(gitignore: "# comment\n*.generated.swift\n/secrets\nlogs/\n!keep.swift\n")
        XCTAssertTrue(ignore.ignores("node_modules/react/index.js"))
        XCTAssertTrue(ignore.ignores(".git/config"))
        XCTAssertTrue(ignore.ignores("build/out.js"))
        XCTAssertTrue(ignore.ignores(".env"))
        XCTAssertTrue(ignore.ignores("Sources/Model.generated.swift"))
        XCTAssertTrue(ignore.ignores("secrets/key.swift"))
        XCTAssertTrue(ignore.ignores("app/logs/today.py"))
        XCTAssertFalse(ignore.ignores("Sources/App.swift"))
        XCTAssertFalse(ignore.ignores("other/secrets/ok.swift"))
        XCTAssertFalse(ignore.ignores(".github/workflows/ci.yml"))
        XCTAssertTrue(CodeLanguage.isReviewable("main.go"))
        XCTAssertFalse(CodeLanguage.isReviewable("photo.png"))
    }

    func testBinaryAndLargeFilesAreNotText() {
        XCTAssertNil(ReviewIgnore.text(from: Data([0x41, 0x00, 0x42])))
        XCTAssertNil(ReviewIgnore.text(from: Data(repeating: 0x41, count: ReviewIgnore.maxBytes + 1)))
        XCTAssertEqual(ReviewIgnore.text(from: Data("let a = 1\n".utf8)), "let a = 1\n")
    }
}

/// Private chats: AES-GCM with an injected key (never the Keychain in tests).
final class PrivateStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olo-private-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sample() -> LocalConversation {
        LocalConversation(title: "My symptoms", turns: [Turn(role: .user, text: "A private question"), Turn(role: .assistant, text: "An answer", origin: .olo)], isPrivate: true)
    }

    func testRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let store = PrivateStore(root: tempDir(), key: key)
        let c = sample()
        try store.save([c, LocalConversation(title: "Not private")])
        let back = try store.load()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.id, c.id)
        XCTAssertEqual(back.first?.turns.map(\.text), ["A private question", "An answer"])
        XCTAssertTrue(back.first?.isPrivate ?? false)
        // Nothing readable on disk.
        let raw = try Data(contentsOf: store.fileURL)
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "private question"))
    }

    func testTamperingFails() throws {
        let key = SymmetricKey(size: .bits256)
        let store = PrivateStore(root: tempDir(), key: key)
        try store.save([sample()])
        var raw = try Data(contentsOf: store.fileURL)
        raw[raw.count - 20] ^= 0x01
        try raw.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testWrongKeyFails() throws {
        let dir = tempDir()
        try PrivateStore(root: dir, key: SymmetricKey(size: .bits256)).save([sample()])
        XCTAssertThrowsError(try PrivateStore(root: dir, key: SymmetricKey(size: .bits256)).load())
    }

    func testSealRejectsOtherData() {
        XCTAssertThrowsError(try PrivateCrypto.open(Data("{}".utf8), key: SymmetricKey(size: .bits256))) { e in
            XCTAssertEqual(e as? PrivateCrypto.Failure, .notPrivateData)
        }
    }

    func testEmptyStoreLoadsNothing() throws {
        XCTAssertEqual(try PrivateStore(root: tempDir(), key: SymmetricKey(size: .bits256)).load().count, 0)
    }

    func testPlainStoreNeverWritesPrivateChats() {
        let store = LocalStore(root: tempDir())
        store.saveConversations([sample(), LocalConversation(title: "Shared")])
        XCTAssertEqual(store.conversations().map(\.title), ["Shared"])
    }

    func testOlderConversationFilesStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","serverId":3,"title":"Old","updatedAt":"2026-10-20T10:00:00Z","turns":[],"isPinned":false}]"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let list = try d.decode([LocalConversation].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.serverId, 3)
        XCTAssertFalse(list.first?.isPrivate ?? true)
        XCTAssertNil(list.first?.addToBrain)
    }
}

/// The Olo brain: the stream event, the stream input, auth.me and the direct call.
final class BrainTests: XCTestCase {
    func testBrainStreamEvent() {
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"brain","status":"published"}"#), .brain(status: "published"))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"brain"}"#), .other("brain"))
        var o = StreamOutcome()
        o.apply(.brain(status: "held"))
        XCTAssertEqual(o.brainStatus, "held")
        XCTAssertNotNil(BrainText.note(for: "published"))
        XCTAssertNil(BrainText.note(for: "unknown"))
    }

    func testAskInputCarriesBrainPrivateAndClient() throws {
        let shared = String(decoding: try JSONEncoder().encode(OloAPI.AskInput(conversationId: 4, content: "q", brain: true)), as: UTF8.self)
        XCTAssertTrue(shared.contains(#""brain":true"#))
        XCTAssertTrue(shared.contains(#""private":false"#))
        XCTAssertTrue(shared.contains(#""client":"macos""#))
        let priv = String(decoding: try JSONEncoder().encode(OloAPI.AskInput(conversationId: nil, content: "q", brain: true, isPrivate: true)), as: UTF8.self)
        XCTAssertTrue(priv.contains(#""private":true"#))
        XCTAssertTrue(priv.contains(#""ghost":true"#))
        XCTAssertTrue(priv.contains(#""brain":false"#))
    }

    func testBrainSharingStateFromAuthMe() {
        func state(_ s: String) -> BrainSharingState {
            BrainSharingState.read(try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)))
        }
        XCTAssertEqual(state(#"{"id":"acct_1","brainSharing":true}"#), .chosen(true))
        XCTAssertEqual(state(#"{"id":"acct_1","brainSharing":false}"#), .chosen(false))
        XCTAssertEqual(state(#"{"id":"acct_1","brainSharing":null}"#), .notAsked)
        XCTAssertEqual(state(#"{"id":"acct_1"}"#), .unknown)
        XCTAssertEqual(state(#"{"user":{"brainSharing":null}}"#), .notAsked)
        XCTAssertEqual(state("null"), .unknown)
    }

    func testBrainAskRequest() throws {
        let ids = (1...20).map { "a\($0)" } + ["a1"]
        let body = try XCTUnwrap(BrainAsk.body(question: "  " + String(repeating: "x", count: 600), atoms: ids, answered: true))
        XCTAssertEqual(body.question.count, 500)
        XCTAssertEqual(body.atoms.count, 12)
        XCTAssertEqual(body.client, "macos")
        XCTAssertNil(BrainAsk.body(question: "   ", atoms: [], answered: false))
        let req = try BrainAsk.request(body)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNil(req.value(forHTTPHeaderField: "apikey"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(req.url!.absoluteString.hasSuffix("/functions/v1/olo-brain-ask"))
    }

    func testPrivateContextCarriesEarlierTurns() {
        let none = PrivateContext.compose(earlier: [], content: "Now?")
        XCTAssertEqual(none, "Now?")
        let out = PrivateContext.compose(earlier: [(role: "user", text: "First"), (role: "assistant", text: "Reply")], content: "Now?")
        XCTAssertTrue(out.hasPrefix("--- Earlier in this private chat ---"))
        XCTAssertTrue(out.contains("Me: First"))
        XCTAssertTrue(out.contains("Olo: Reply"))
        XCTAssertTrue(out.hasSuffix("Now?"))
    }
}
