import XCTest
@testable import OloKit

final class StreamTests: XCTestCase {
    func testParsesEveryEventTheMacUses() {
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"start","conversationId":42}"#), .start(conversationId: 42))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"delta","text":"Hel"}"#), .delta("Hel"))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"notice","message":"Using the backup writer."}"#), .notice("Using the backup writer."))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"answer_complete","conversationId":42,"messageId":7}"#), .answerComplete(conversationId: 42, messageId: 7))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"error","message":"Limit","code":"quota_exceeded"}"#), .error(message: "Limit", detail: nil, code: "quota_exceeded"))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"followups","questions":["a",1,"b"]}"#), .followUps(["a", "b"]))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"artifact","artifact":{}}"#), .other("artifact"))
        let s = StreamEvent.parse(line: #"{"type":"sources","sources":[{"index":1,"title":"T","url":"https://x.org","reliability":null}]}"#)
        XCTAssertEqual(s, .sources([Source(index: 1, title: "T", url: "https://x.org")]))
    }

    func testSkipsBlankAndBrokenLines() {
        XCTAssertNil(StreamEvent.parse(line: ""))
        XCTAssertNil(StreamEvent.parse(line: "   "))
        XCTAssertNil(StreamEvent.parse(line: "{not json"))
        XCTAssertNil(StreamEvent.parse(line: #"{"no":"type"}"#))
    }

    func testVerificationEvent() {
        let line = #"{"type":"verification","verification":{"claims":[{"claim":"A","verdict":"supported","citedBy":[1],"rationale":"r","excerpt":"e"},{"claim":"B","verdict":"unsupported","citedBy":[],"rationale":""}],"supported":1,"unsupported":1,"contradicted":0,"score":0.5}}"#
        guard case .verification(let v)? = StreamEvent.parse(line: line) else { return XCTFail("no verification") }
        XCTAssertEqual(v.claims.count, 2)
        XCTAssertEqual(v.supported, 1)
        XCTAssertEqual(v.claims[0].excerpt, "e")
    }

    func testLineBufferKeepsPartialLines() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data(#"{"type":"delta","te"#.utf8)), [])
        XCTAssertEqual(b.append(Data("xt\":\"a\"}\n{\"type\":\"delta\",\"text\":\"b\"}\n{\"ty".utf8)), [#"{"type":"delta","text":"a"}"#, #"{"type":"delta","text":"b"}"#])
        XCTAssertEqual(b.finish(), #"{"ty"#)
        XCTAssertNil(b.finish())
    }

    func testLineBufferHandlesMultibyteSplitAcrossChunks() {
        var b = LineBuffer()
        let bytes = Array("caf\u{00E9}\n".utf8)
        XCTAssertEqual(b.append(Data(bytes[0..<4])), [])
        XCTAssertEqual(b.append(Data(bytes[4...])), ["caf\u{00E9}"])
    }

    func testOutcomeMarksCompletionOnlyOnAnswerComplete() {
        var o = StreamOutcome()
        o.apply(.start(conversationId: 3))
        o.apply(.delta("Hello "))
        o.apply(.delta("world."))
        XCTAssertFalse(o.completed)
        o.apply(.answerComplete(conversationId: nil, messageId: 9))
        XCTAssertTrue(o.completed)
        XCTAssertEqual(o.conversationId, 3)
        XCTAssertEqual(o.messageId, 9)
        XCTAssertEqual(o.text, "Hello world.")
    }
}

final class TRPCTests: XCTestCase {
    let base = URL(string: "https://helius-olo.io")!

    func testQueryEncodesSuperjsonInput() throws {
        let req = try TRPC.queryRequest(base: base, path: "chat.getMessages", input: OloAPI.ConversationInput(conversationId: 5), token: "tok")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/api/trpc/chat.getMessages")
        XCTAssertEqual(comps.queryItems?.first?.value, #"{"json":{"conversationId":5}}"#)
    }

    func testQueryWithoutInputHasNoQuery() throws {
        let req = try TRPC.queryRequest(base: base, path: "chat.listConversations", token: nil)
        XCTAssertNil(req.url?.query)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testPlusSignsSurviveTheQueryString() throws {
        let req = try TRPC.queryRequest(base: base, path: "chat.search", input: ["query": "c++ a+b"], token: nil)
        XCTAssertFalse(req.url!.absoluteString.contains("+"))
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.queryItems?.first?.value, #"{"json":{"query":"c++ a+b"}}"#)
    }

    func testMutationBody() throws {
        let req = try TRPC.mutationRequest(base: base, path: "auth.requestEmailCode", input: OloAPI.EmailInput(email: "a@b.co"), token: nil)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(String(decoding: req.httpBody!, as: UTF8.self), #"{"json":{"email":"a@b.co"}}"#)
    }

    func testDecodesResultAndError() throws {
        let ok = Data(#"{"result":{"data":{"json":{"token":"t","user":{"id":"usr_1","name":null,"email":null,"role":"user","createdAt":"2026-10-24T10:00:00.000Z"}}}}}"#.utf8)
        let s = try TRPC.decode(SessionResult.self, data: ok, status: 200)
        XCTAssertEqual(s.token, "t")
        XCTAssertTrue(s.user.isAnonymous)

        let bad = Data(#"{"error":{"json":{"message":"Please sign in (10001)","code":-32001,"data":{"code":"UNAUTHORIZED","httpStatus":401}}}}"#.utf8)
        XCTAssertThrowsError(try TRPC.decode(SessionResult.self, data: bad, status: 401)) { e in
            let r = e as? TRPC.RemoteError
            XCTAssertEqual(r?.code, "UNAUTHORIZED")
            XCTAssertTrue(r?.isUnauthorized ?? false)
            XCTAssertEqual(r?.message, "Please sign in (10001)")
        }
    }

    func testMessagesDecodeWithStoredJSONText() throws {
        let data = Data(#"""
        {"result":{"data":{"json":[
          {"id":1,"conversationId":2,"role":"user","content":"Q","citations":null,"verification":null,"sources":null,"files":null,"createdAt":"2026-10-24T10:00:00.000Z"},
          {"id":2,"conversationId":2,"role":"assistant","content":"A","citations":null,
           "verification":"{\"claims\":[{\"claim\":\"A\",\"verdict\":\"supported\",\"citedBy\":[1],\"rationale\":\"\"}],\"supported\":1,\"unsupported\":0,\"contradicted\":0,\"score\":1}",
           "sources":[{"index":1,"title":"S","url":"https://s.org"}],"files":null,"createdAt":"2026-10-24T10:00:01Z"}
        ]}}}
        """#.utf8)
        let msgs = try TRPC.decode([Message].self, data: data, status: 200)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertNil(msgs[0].verification)
        XCTAssertEqual(msgs[1].verification?.supported, 1)
        XCTAssertEqual(msgs[1].sources?.first?.url, "https://s.org")
        let turn = Turn(message: msgs[1])
        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.origin, .olo)
    }

    func testConversationsTolerateNulls() throws {
        let data = Data(#"{"result":{"data":{"json":[{"id":9,"userId":"u","title":null,"tags":null,"folder":null,"folderColor":null,"isPinned":true,"summary":null,"summaryThrough":null,"forkedFrom":null,"createdAt":"2026-10-24T10:00:00Z","updatedAt":"2026-10-24T11:00:00Z"}]}}}"#.utf8)
        let list = try TRPC.decode([Conversation].self, data: data, status: 200)
        XCTAssertEqual(list.first?.title, "New conversation")
        XCTAssertEqual(list.first?.isPinned, true)
    }

    func testAskInputOmitsMissingConversation() throws {
        let body = String(decoding: try JSONEncoder().encode(OloAPI.AskInput(conversationId: nil, content: "hi")), as: UTF8.self)
        XCTAssertFalse(body.contains("conversationId"))
        XCTAssertTrue(body.contains(#""content":"hi""#))
    }
}

final class CommonsTests: XCTestCase {
    func testSnapshotDecodesByColumnName() throws {
        let json = #"{"v":1,"built_at":"2026-10-24T12:00:00Z","count":2,"licence_note":"Each atom keeps its licence.","fields":["id","title","text","url","source","licence","published_at","extra"],"atoms":[["a1","Project Gutenberg","Project Gutenberg was founded in 1971 by Michael S. Hart.","https://en.wikipedia.org/wiki/Project_Gutenberg","Wikipedia","CC BY-SA 4.0",null,1],["a2","Empty","","","","",null,0]]}"#
        let s = try CommonsSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].licence, "CC BY-SA 4.0")
        XCTAssertNil(s.atoms[0].publishedAt)
        XCTAssertEqual(s.builtAt, "2026-10-24T12:00:00Z")
    }

    func testSnapshotRejectsUnknownVersion() {
        XCTAssertThrowsError(try CommonsSnapshot.decode(Data(#"{"v":2,"fields":[],"atoms":[]}"#.utf8)))
        XCTAssertThrowsError(try CommonsSnapshot.decode(Data("nope".utf8)))
    }

    func testCommonsAnswerMapsToVerdicts() throws {
        let json = #"{"q":"x","covered":true,"answer":"A. B.","sentences":[{"text":"A.","citations":["p2"],"verdict":"supported","evidence":[{"passage":"p2","quote":"a"}],"rationale":"r"},{"text":"B.","citations":[],"verdict":"not_covered","evidence":[],"rationale":""}],"passages":[{"id":"p1","title":"One","url":"https://1"},{"id":"p2","title":"Two","url":"https://2"}],"verifier":"zeus:default_model","mode":"written"}"#
        let a = try JSONDecoder().decode(CommonsAnswer.self, from: Data(json.utf8))
        let v = try XCTUnwrap(a.asVerification)
        XCTAssertEqual(v.supported, 1)
        XCTAssertEqual(v.unsupported, 1)
        XCTAssertEqual(v.claims[0].citedBy, [2])
        XCTAssertEqual(v.claims[0].excerpt, "a")
        XCTAssertEqual(a.asSources.map(\.title), ["One", "Two"])
    }

    func testCommonsRequestSendsNumberK() throws {
        let req = try CommonsAnswer.request(question: "who", k: 6)
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
        XCTAssertEqual(body?["k"] as? Int, 6)
        XCTAssertEqual(body?["q"] as? String, "who")
    }
}

final class SearchTests: XCTestCase {
    let atoms = [
        Passage(title: "Project Gutenberg", text: "Project Gutenberg was founded in 1971 by Michael S. Hart. It is the oldest digital library.", url: "https://g", origin: "Wikipedia"),
        Passage(title: "Photosynthesis", text: "Photosynthesis turns light into chemical energy. Plants and algae do it.", url: "https://p", origin: "Wikipedia"),
        Passage(title: "Libraries", text: "A library is a collection of books. Many libraries are public.", url: "https://l", origin: "Wikipedia"),
    ]

    func testTokenizerDropsStopwordsAndPunctuation() {
        XCTAssertEqual(Tokenizer.tokens("Who founded Project Gutenberg?"), ["founded", "project", "gutenberg"])
        XCTAssertEqual(Tokenizer.tokens("caf\u{00E9} 2026!"), ["caf\u{00E9}", "2026"])
    }

    func testIndexRanksTheRightPassageFirst() {
        let idx = SearchIndex(atoms, title: \.title, text: \.text)
        XCTAssertEqual(idx.search("who founded project gutenberg").first?.doc.title, "Project Gutenberg")
        XCTAssertEqual(idx.search("how do plants make energy from light").first?.doc.title, "Photosynthesis")
        XCTAssertTrue(idx.search("the of and").isEmpty)
    }

    func testSentencesKeepInitialsAndAbbreviations() {
        XCTAssertEqual(Sentences.split("Founded by Michael S. Hart. It is old."), ["Founded by Michael S. Hart.", "It is old."])
        XCTAssertEqual(Sentences.split("Ask Dr. Smith today. Then rest!"), ["Ask Dr. Smith today.", "Then rest!"])
        XCTAssertEqual(Sentences.split("Version 2.5 shipped. \"Great,\" she said."), ["Version 2.5 shipped.", "\"Great,\" she said."])
        XCTAssertEqual(Sentences.split("no ending here"), ["no ending here"])
    }

    func testQuotedAnswerQuotesAndCites() {
        let a = QuotedAnswer.compose(question: "who founded project gutenberg", passages: atoms)
        XCTAssertTrue(a.covered)
        XCTAssertTrue(a.text.contains("\"Project Gutenberg was founded in 1971 by Michael S. Hart.\" [1]"))
        XCTAssertEqual(a.sources.first?.url, "https://g")
    }

    func testQuotedAnswerSaysWhenNothingCoversIt() {
        let a = QuotedAnswer.compose(question: "quantum chromodynamics", passages: atoms)
        XCTAssertFalse(a.covered)
        XCTAssertEqual(a.text, QuotedAnswer.notCovered)
    }

    func testChunkerSplitsLongTextAtSentences() {
        let text = (1...60).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let chunks = Chunker.chunks(text, size: 200)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 260 })
        XCTAssertTrue(chunks[0].hasPrefix("Sentence number 1 is here."))
    }
}

final class ComposeTests: XCTestCase {
    func testAttachmentsAreFencedBeforeTheQuestion() {
        let r = MessageComposer.compose(question: "Summarise", attachments: [
            Attachment(kind: .selection, name: "Selection", text: "Some words"),
            Attachment(kind: .file, name: "report.pdf", text: "Body"),
        ])
        XCTAssertEqual(r.content, "--- Selected text ---\nSome words\n--- End of selected text ---\n\n--- Attached: report.pdf ---\nBody\n--- End of report.pdf ---\n\nSummarise")
        XCTAssertTrue(r.trimmed.isEmpty)
    }

    func testLargeAttachmentsAreTrimmed() {
        let big = String(repeating: "a", count: 50_000)
        let r = MessageComposer.compose(question: "q", attachments: [Attachment(kind: .file, name: "big.txt", text: big), Attachment(kind: .file, name: "b2.txt", text: big), Attachment(kind: .file, name: "b3.txt", text: big)])
        XCTAssertEqual(r.trimmed, ["big.txt", "b2.txt", "b3.txt"])
        XCTAssertLessThan(r.content.count, MessageComposer.totalBudget + 1_000)
    }

    func testNoAttachmentsMeansTheQuestionAlone() {
        XCTAssertEqual(MessageComposer.compose(question: "  hi \n", attachments: []).content, "hi")
    }

    func testLinkPolicy() {
        XCTAssertTrue(LinkPolicy.isSafeExternal(URL(string: "https://example.org")!))
        XCTAssertTrue(LinkPolicy.isSafeExternal(URL(string: "mailto:a@b.co")!))
        XCTAssertFalse(LinkPolicy.isSafeExternal(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(LinkPolicy.isSafeExternal(URL(string: "javascript:alert(1)")!))
        XCTAssertEqual(LinkPolicy.parse(URL(string: "olo://ask?q=hello%20world")!), .ask("hello world"))
        XCTAssertEqual(LinkPolicy.parse(URL(string: "olo://chat/42")!), .conversation(42))
        XCTAssertNil(LinkPolicy.parse(URL(string: "https://helius-olo.io")!))
    }

    func testTitles() {
        XCTAssertEqual(LocalConversation.title(for: "Short question\nsecond line"), "Short question")
        XCTAssertEqual(LocalConversation.title(for: String(repeating: "x", count: 80)).count, 60)
    }

    func testLocalStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(root: dir)
        let c = LocalConversation(serverId: 4, title: "T", turns: [Turn(role: .user, text: "Q"), Turn(role: .assistant, text: "A", origin: .offline)])
        store.saveConversations([c])
        XCTAssertEqual(store.conversations().first?.turns.last?.origin, .offline)
        store.savePending([PendingQuestion(question: "Q", content: "Q", localConversation: c.id)])
        XCTAssertEqual(store.pending().count, 1)
        store.eraseAll()
        XCTAssertTrue(store.conversations().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}
