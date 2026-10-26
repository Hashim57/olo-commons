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

final class AbstainTests: XCTestCase {
    let claims = [
        ClaimVerdict(claim: "Paris is the capital of France", verdict: "supported", citedBy: [1]),
        ClaimVerdict(claim: "Paris has about two million residents", verdict: "contradicted", citedBy: [2]),
    ]

    func testShowsOnlySupportedSentences() {
        let text = "Paris is the capital of France [1]. It has about two million residents [2]. Enjoy your trip."
        let r = Abstain.splitShown(text: text, claims: claims)
        XCTAssertEqual(r.shown, ["Paris is the capital of France [1]."])
        XCTAssertEqual(r.hidden.map(\.0), ["It has about two million residents [2].", "Enjoy your trip."])
        XCTAssertEqual(r.hidden.map(\.1), ["contradicted", Abstain.unmatched])
    }

    func testNeedsSixtyPercentOfTheClaimsContentWords() {
        let c = [ClaimVerdict(claim: "The Eiffel Tower was finished in 1889 in Paris", verdict: "supported")]
        let r = Abstain.splitShown(text: "The tower is tall. The Eiffel Tower was finished in 1889.", claims: c)
        XCTAssertEqual(r.shown, ["The Eiffel Tower was finished in 1889."])
        XCTAssertEqual(r.hidden.map(\.1), [Abstain.unmatched])
    }

    func testPicksTheClaimSharingMostWords() {
        let c = [
            ClaimVerdict(claim: "Water boils at 100 degrees", verdict: "unsupported"),
            ClaimVerdict(claim: "Water boils at 100 degrees Celsius at sea level", verdict: "supported"),
        ]
        let r = Abstain.splitShown(text: "Water boils at 100 degrees Celsius at sea level.", claims: c)
        XCTAssertEqual(r.shown.count, 1)
        XCTAssertTrue(r.hidden.isEmpty)
    }

    func testNothingSupportedHidesEverything() {
        let c = [ClaimVerdict(claim: "Paris is the capital of France", verdict: "unsupported")]
        let r = Abstain.splitShown(text: "Paris is the capital of France.", claims: c)
        XCTAssertTrue(r.shown.isEmpty)
        XCTAssertEqual(r.hidden.map(\.1), ["unsupported"])
        XCTAssertEqual(Abstain.label(for: "unsupported"), "Not covered by its sources")
    }

    func testSplitsListItemsOnTheirOwnLines() {
        let c = [ClaimVerdict(claim: "Oak trees drop acorns", verdict: "supported")]
        let r = Abstain.splitShown(text: "- Oak trees drop acorns\n- Pines keep their needles", claims: c)
        XCTAssertEqual(r.shown, ["- Oak trees drop acorns"])
        XCTAssertEqual(r.hidden.map(\.0), ["- Pines keep their needles"])
    }

    func testEmptyTextAndNoClaims() {
        XCTAssertTrue(Abstain.splitShown(text: "", claims: claims).shown.isEmpty)
        let r = Abstain.splitShown(text: "Hello there.", claims: [])
        XCTAssertEqual(r.hidden.map(\.1), [Abstain.unmatched])
    }

    func testAnsweredByLineAndPublishers() {
        XCTAssertEqual(AnsweredBy(writer: "claude-sonnet-4", provider: "anthropic", verifier: "zeus:v7").line,
                       "Answered by claude-sonnet-4 via anthropic, checked by zeus:v7")
        XCTAssertEqual(AnsweredBy(writer: nil, provider: nil, verifier: "zeus:v7").line, "Checked by zeus:v7")
        XCTAssertNil(AnsweredBy(writer: nil, provider: nil, verifier: nil).line)
        let sources = [Source(index: 1, title: "A", url: "https://www.bbc.co.uk/news/1"), Source(index: 2, title: "B", url: "https://bbc.co.uk/news/2"),
                       Source(index: 3, title: "C", url: "https://en.wikipedia.org/wiki/X"), Source(index: 4, title: "D", url: "")]
        XCTAssertEqual(Publishers.hosts(of: sources), ["bbc.co.uk", "en.wikipedia.org"])
        XCTAssertEqual(Publishers.summary(of: sources), "4 sources from 2 independent publishers")
        XCTAssertNil(Publishers.summary(of: []))
        XCTAssertEqual(Publishers.summary(of: [sources[0]]), "1 source from 1 independent publisher")
    }

    func testAnsweredByStreamEventAndVerificationPayload() throws {
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"answered_by","writer":"gpt-4.1","writer_provider":"openai","verifier":"zeus:v7"}"#),
                       .answeredBy(writer: "gpt-4.1", provider: "openai", verifier: "zeus:v7"))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"answered_by","writer":"m","provider":"cloudflare"}"#),
                       .answeredBy(writer: "m", provider: "cloudflare", verifier: nil))
        let inside = #"{"type":"verification","verification":{"claims":[],"answered_by":{"writer":"w","writer_provider":"p","verifier":"z"}}}"#
        guard case .verification(let v)? = StreamEvent.parse(line: inside) else { return XCTFail("no verification") }
        XCTAssertEqual(v.answeredBy, AnsweredBy(writer: "w", provider: "p", verifier: "z"))
        let beside = #"{"type":"verification","verification":{"claims":[]},"answered_by":{"writer":"w2","verifier":"z2"}}"#
        guard case .verification(let v2)? = StreamEvent.parse(line: beside) else { return XCTFail("no verification") }
        XCTAssertEqual(v2.answeredBy?.writer, "w2")
        var o = StreamOutcome()
        o.apply(.answeredBy(writer: "w3", provider: nil, verifier: nil))
        XCTAssertEqual(o.answeredBy?.writer, "w3")
        // Round trip through the local store keeps it.
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(AnswerVerification.self, from: data).answeredBy?.provider, "p")
    }

    func testTurnDecodesWithoutTheNewFields() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"A","sources":[],"notices":[],"followUps":[],"attachments":[],"createdAt":"2026-10-24T10:00:00Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let t = try d.decode(Turn.self, from: Data(old.utf8))
        XCTAssertNil(t.writer)
        XCTAssertNil(t.answeredBy)
        var t2 = t
        t2.setAnsweredBy(AnsweredBy(writer: "w", provider: nil, verifier: "z"))
        XCTAssertEqual(t2.answeredBy?.line, "Answered by w, checked by z")
    }

    func testCommonsAnswerCarriesAnsweredBy() throws {
        let json = #"{"answer":"A.","model":"llama","verifier":"zeus:v7","answered_by":{"writer":"llama","writer_provider":"api.groq.com","verifier":"zeus:v7","mode":"written"}}"#
        let a = try JSONDecoder().decode(CommonsAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.attribution, AnsweredBy(writer: "llama", provider: "api.groq.com", verifier: "zeus:v7"))
        let older = try JSONDecoder().decode(CommonsAnswer.self, from: Data(#"{"answer":"A.","model":"m","verifier":"v"}"#.utf8))
        XCTAssertEqual(older.attribution, AnsweredBy(writer: "m", provider: nil, verifier: "v"))
    }
}

final class FeedbackTests: XCTestCase {
    func testBodyShapeAndUnsupportedMapping() throws {
        let claim = ClaimVerdict(claim: "The Thames is 215 miles long", verdict: "unsupported", citedBy: [2], rationale: "", excerpt: "215 miles")
        let sources = [Source(index: 1, title: "A", url: "https://a.org/1"), Source(index: 2, title: "B", url: "https://b.org/2")]
        let req = try FeedbackRequest.build(answerSource: .olo, claim: claim, sources: sources, userVerdict: "supported", note: "  It is in the source.  ")
        XCTAssertEqual(req.url, FeedbackRequest.endpoint)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["client"] as? String, "macos")
        XCTAssertEqual(body["answer_source"] as? String, "olo")
        XCTAssertEqual(body["claim"] as? String, "The Thames is 215 miles long")
        XCTAssertEqual(body["verdict_given"] as? String, "not_covered")
        XCTAssertEqual(body["verdict_user"] as? String, "supported")
        XCTAssertEqual(body["note"] as? String, "It is in the source.")
        let passages = try XCTUnwrap(body["passages"] as? [[String: Any]])
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0]["url"] as? String, "https://b.org/2")
        XCTAssertEqual(passages[0]["quote"] as? String, "215 miles")
        XCTAssertEqual(Set(body.keys), ["client", "answer_source", "claim", "verdict_given", "verdict_user", "passages", "note"])
    }

    func testVerdictNamesAndEmptyNote() throws {
        XCTAssertEqual(FeedbackRequest.givenVerdict("supported"), "supported")
        XCTAssertEqual(FeedbackRequest.givenVerdict("contradicted"), "contradicted")
        XCTAssertEqual(FeedbackRequest.givenVerdict("unsupported"), "not_covered")
        XCTAssertEqual(FeedbackRequest.givenVerdict("anything"), "not_covered")
        let req = try FeedbackRequest.build(answerSource: .commons, claim: ClaimVerdict(claim: "C", verdict: "supported"), sources: [], userVerdict: "wrong_source", note: "   ")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["answer_source"] as? String, "commons")
        XCTAssertNil(body["note"])
        XCTAssertEqual((body["passages"] as? [Any])?.count, 0)
        XCTAssertEqual(FeedbackRequest.userChoices.map(\.value), ["supported", "contradicted", "not_covered", "wrong_source", "unclear"])
    }

    func testMessagesForStatuses() {
        XCTAssertEqual(FeedbackRequest.message(forStatus: 200), FeedbackRequest.sent)
        XCTAssertEqual(FeedbackRequest.message(forStatus: 429), FeedbackRequest.tooMany)
        XCTAssertEqual(FeedbackRequest.message(forStatus: 500), FeedbackRequest.failed)
        XCTAssertEqual(FeedbackRequest.message(forStatus: 0), FeedbackRequest.failed)
    }

    func testConsentMutationBody() throws {
        let req = try TRPC.mutationRequest(base: URL(string: "https://helius-olo.io")!, path: "auth.setTrainingConsent", input: OloAPI.ConsentInput(consent: true), token: "t")
        XCTAssertEqual(req.url?.path, "/api/trpc/auth.setTrainingConsent")
        XCTAssertEqual(String(decoding: req.httpBody!, as: UTF8.self), #"{"json":{"consent":true}}"#)
        let notFound = Data(#"{"error":{"json":{"message":"No procedure","code":-32004,"data":{"code":"NOT_FOUND","httpStatus":404}}}}"#.utf8)
        XCTAssertThrowsError(try TRPC.decode(JSONValue.self, data: notFound, status: 404)) { e in
            XCTAssertTrue((e as? TRPC.RemoteError)?.isNotFound ?? false)
        }
    }
}

final class CrisisTests: XCTestCase {
    func testFirstPersonPhrasesTrip() {
        for s in ["I want to die", "i want to die.", "I don't want to live anymore", "I dont want to live", "I'm going to kill myself tonight",
                  "sometimes I think about ending my life", "I feel suicidal", "I\u{2019}m suicidal and scared", "I want to hurt myself",
                  "there is no reason to live", "I can't go on", "I wish I were dead"] {
            XCTAssertTrue(Crisis.detect(s), s)
        }
    }

    func testOtherUsesStayQuiet() {
        for s in ["suicide rates in the UK", "kill the process on port 8080", "I would die on this hill", "how to kill a Python thread",
                  "I don't want to live in London anymore", "my friend said he wants to kill himself, how can I help",
                  "the suicide prevention charity Samaritans", "I'm dying to see the new film", "I nearly killed myself laughing",
                  "I want to die of embarrassment", "what is the history of the word suicide", "", "Explain photosynthesis"] {
            XCTAssertFalse(Crisis.detect(s), s)
        }
    }

    func testHelplinesArePresent() {
        XCTAssertTrue(Crisis.helplines.contains { $0.detail.contains("116 123") })
        XCTAssertTrue(Crisis.helplines.contains { $0.detail.contains("85258") })
        XCTAssertTrue(Crisis.emergency.contains("999") && Crisis.emergency.contains("112"))
    }
}
