import XCTest
@testable import OloKit

/// Fixtures copied from the web's types (client/src/lib/chatStream.ts, server/*.ts),
/// decoded the way the Mac receives them.
final class MemoryTests: XCTestCase {
    func testListDecodesWithStatusAndCap() throws {
        let data = Data(#"""
        {"result":{"data":{"json":{"memories":[
          {"id":"m1","category":"profile","content":"I run a small design studio in Anguilla.","status":"approved","conversationId":12,"projectId":null,"uses":3,"lastUsedAt":"2026-10-20T10:00:00.000Z","createdAt":"2026-10-01T10:00:00.000Z"},
          {"id":"m2","category":"preference","content":"Prefers British spelling and short answers.","status":"proposed","conversationId":15,"projectId":null,"uses":0,"lastUsedAt":null,"createdAt":"2026-10-24T10:00:00.000Z"}
        ],"enabled":true,"cap":200}}}}
        """#.utf8)
        let list = try TRPC.decode(MemoryList.self, data: data, status: 200)
        XCTAssertEqual(list.memories.count, 2)
        XCTAssertEqual(list.proposed.map(\.id), ["m2"])
        XCTAssertEqual(list.approved.map(\.id), ["m1"])
        XCTAssertTrue(list.enabled)
        XCTAssertEqual(list.cap, 200)
        XCTAssertFalse(list.nearCap)
    }

    func testOlderServerWithoutStatusCountsAsApproved() throws {
        let data = Data(#"{"result":{"data":{"json":{"memories":[{"id":"m1","category":"fact","content":"x","uses":0,"createdAt":"2026-10-01T10:00:00Z"}],"enabled":false}}}}"#.utf8)
        let list = try TRPC.decode(MemoryList.self, data: data, status: 200)
        XCTAssertFalse(list.memories[0].isProposed)
        XCTAssertFalse(list.enabled)
        XCTAssertEqual(list.cap, 200)
    }

    func testMarkdownGroupsByCategoryAndMarksProposed() {
        let export = MemoryExport(exportedAt: "2026-10-25T09:00:00.000Z", cap: 200, memories: [
            Memory(id: "a", category: "preference", content: "Short answers.", status: "proposed"),
            Memory(id: "b", category: "profile", content: "Runs a studio.", uses: 2),
            Memory(id: "c", category: "odd", content: "Something else."),
        ])
        let md = MemoryMarkdown.render(export)
        XCTAssertTrue(md.hasPrefix("# What Olo remembers"))
        let profile = md.range(of: "## About you")!.lowerBound
        let preference = md.range(of: "## How you like answers")!.lowerBound
        XCTAssertLessThan(profile, preference, "categories keep the web's order")
        XCTAssertTrue(md.contains("- Short answers. (proposed, not yet approved)"))
        XCTAssertTrue(md.contains("- Runs a studio. [used 2 times]"))
        XCTAssertTrue(md.contains("## Other\n\n- Something else."))
        XCTAssertFalse(md.contains("\u{2014}"))
        XCTAssertFalse(md.contains("\u{2013}"))
        XCTAssertEqual(MemoryMarkdown.filename(on: Date(timeIntervalSince1970: 1_793_000_000)), "olo-memory-2026-10-26.md")
    }

    func testMemoryInputsEncodeTheServerKeys() throws {
        let add = String(decoding: try JSONEncoder().encode(OloAPI.MemoryAddInput(category: "fact", content: "Uses a Mac.")), as: UTF8.self)
        XCTAssertTrue(add.contains(#""category":"fact""#))
        let enabled = String(decoding: try JSONEncoder().encode(OloAPI.EnabledInput(enabled: false)), as: UTF8.self)
        XCTAssertEqual(enabled, #"{"enabled":false}"#)
    }
}

final class ArtifactTests: XCTestCase {
    let streamed = #"{"type":"artifact","artifact":{"id":"art_1","kind":"html","language":"html","title":"Landing page","filename":"index.html","code":"<h1>Hi</h1>","validated":true,"repaired":false,"issues":[{"severity":"warning","message":"No viewport meta"}]}}"#

    func testStreamArtifactEvent() throws {
        guard case .artifact(let a)? = StreamEvent.parse(line: streamed) else { return XCTFail("no artifact") }
        XCTAssertEqual(a.id, "art_1")
        XCTAssertEqual(a.kind, "html")
        XCTAssertEqual(a.warnings.count, 1)
        XCTAssertTrue(a.isPreviewable)
        XCTAssertEqual(a.suggestedFilename, "index.html")
        XCTAssertNil(a.version)
    }

    func testRepairedCopyReplacesTheFirst() throws {
        var o = StreamOutcome()
        o.apply(StreamEvent.parse(line: streamed)!)
        o.apply(.artifact(Artifact(id: "art_1", kind: "html", title: "Landing page", filename: "index.html", code: "<h1>Hello</h1>", repaired: true)))
        XCTAssertEqual(o.artifacts.count, 1)
        XCTAssertEqual(o.artifacts[0].code, "<h1>Hello</h1>")
        XCTAssertTrue(o.artifacts[0].repaired)
    }

    func testEmptyArtifactIsSkippedNotAnError() {
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"artifact","artifact":{}}"#), .other("artifact"))
    }

    func testLibraryRowDecodes() throws {
        let data = Data(#"{"result":{"data":{"json":[{"id":"art_9","userId":"u","conversationId":4,"projectId":null,"kind":"markdown","language":"markdown","title":"Notes","filename":"notes","code":"# Notes","validated":true,"repaired":false,"issues":[],"version":2,"createdAt":"2026-10-24T10:00:00Z","updatedAt":"2026-10-24T11:00:00Z"}]}}}"#.utf8)
        let list = try TRPC.decode([Artifact].self, data: data, status: 200)
        XCTAssertEqual(list[0].conversationId, 4)
        XCTAssertEqual(list[0].version, 2)
        XCTAssertEqual(list[0].suggestedFilename, "notes.md")
        XCTAssertFalse(list[0].isPreviewable)
    }

    func testPreviewDocuments() {
        let fragment = Artifact(id: "a", kind: "html", title: "t", filename: "t.html", code: "<p>x</p>")
        XCTAssertTrue(ArtifactPreview.document(for: fragment).hasPrefix("<!doctype html>"))
        let whole = Artifact(id: "a", kind: "html", title: "t", filename: "t.html", code: "<html><body>x</body></html>")
        XCTAssertEqual(ArtifactPreview.document(for: whole), whole.code)
        let code = Artifact(id: "a", kind: "code", language: "py", title: "t", filename: "t", code: "if a < b: print(\"<\")")
        XCTAssertTrue(ArtifactPreview.document(for: code).contains("if a &lt; b: print(&quot;&lt;&quot;)"))
        XCTAssertEqual(code.suggestedFilename, "t.py")
        XCTAssertTrue(Artifact(id: "r", kind: "react", title: "t", filename: "App.jsx", code: "export default function App(){}").needsScripts)
    }

    func testShareDecodesAndBuildsTheLink() throws {
        let data = Data(#"{"result":{"data":{"json":{"token":"abc12345def67890","userId":"u","subjectType":"conversation","subjectId":"42","access":"view","label":null,"revoked":false,"expiresAt":null,"viewCount":0,"createdAt":"2026-10-25T09:00:00Z"}}}}"#.utf8)
        let share = try TRPC.decode(Share.self, data: data, status: 200)
        XCTAssertEqual(share.url().absoluteString, "https://helius-olo.io/s/abc12345def67890")
        XCTAssertEqual(share.subjectId, "42")
        let input = String(decoding: try JSONEncoder().encode(OloAPI.ShareInput(subjectType: "conversation", subjectId: "42")), as: UTF8.self)
        XCTAssertFalse(input.contains("label"))
        XCTAssertTrue(input.contains(#""subjectType":"conversation""#))
    }
}

final class LibraryModelTests: XCTestCase {
    func testOrganizationInputWritesNulls() throws {
        let body = String(decoding: try JSONEncoder().encode(OloAPI.OrganizationInput(conversationId: 3, folder: nil, folderColor: nil, isPinned: true)), as: UTF8.self)
        XCTAssertTrue(body.contains(#""folder":null"#))
        XCTAssertTrue(body.contains(#""folderColor":null"#))
        XCTAssertTrue(body.contains(#""isPinned":true"#))
    }

    func testSearchHitsAndProjectsDecode() throws {
        let hits = Data(#"{"result":{"data":{"json":[{"conversationId":7,"conversationTitle":"Sargassum","messageId":31,"role":"assistant","snippet":"...biofuel feedstock...","createdAt":"2026-10-20T10:00:00Z"}]}}}"#.utf8)
        let list = try TRPC.decode([SearchHit].self, data: hits, status: 200)
        XCTAssertEqual(list[0].conversationId, 7)
        XCTAssertEqual(list[0].id, 31)

        let projects = Data(#"{"result":{"data":{"json":[{"id":2,"userId":"u","name":"Anguilla planning","description":null,"instructions":"Use UK spelling.","kind":"research","color":"#5ec8a6","isArchived":false,"createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z"}]}}}"#.utf8)
        let p = try TRPC.decode([Project].self, data: projects, status: 200)
        XCTAssertEqual(p[0].name, "Anguilla planning")
        XCTAssertEqual(p[0].kind, "research")
        XCTAssertNil(p[0].description)

        let create = String(decoding: try JSONEncoder().encode(OloAPI.ProjectCreateInput(name: "X")), as: UTF8.self)
        XCTAssertEqual(create, #"{"name":"X"}"#)
    }

    func testNudgesDecode() throws {
        let data = Data(#"{"result":{"data":{"json":[{"id":"n1","userId":"u","kind":"thread_idle","subjectId":"42","title":"You left a thread open","body":"Pick it up?","suggestion":"Open it","status":"sent","createdAt":"2026-10-25T08:00:00Z"}]}}}"#.utf8)
        let n = try TRPC.decode([Nudge].self, data: data, status: 200)
        XCTAssertEqual(n[0].conversationId, 42)
        XCTAssertEqual(n[0].suggestion, "Open it")
        XCTAssertNil(Nudge(id: "x", kind: "claim_changed", subjectId: "mon_1", title: "", body: "").conversationId)
    }
}

final class PassageTests: XCTestCase {
    func testEditInputProblems() {
        XCTAssertEqual(EditPassageInput(conversationId: 1, messageId: 2, passage: "ab", instruction: "make it shorter").problem, "Select a few words first.")
        XCTAssertEqual(EditPassageInput(conversationId: 1, messageId: 2, passage: "a good passage", instruction: "x").problem, "Say what should change.")
        XCTAssertNil(EditPassageInput(conversationId: 1, messageId: 2, passage: "a good passage", instruction: "shorter").problem)
        let long = String(repeating: "a", count: 4001)
        XCTAssertNotNil(EditPassageInput(conversationId: 1, messageId: 2, passage: long, instruction: "shorter").problem)
    }

    func testEditResultDecodes() throws {
        let data = Data(#"{"result":{"data":{"json":{"content":"The whole answer, edited.","replacement":"edited."}}}}"#.utf8)
        let r = try TRPC.decode(EditPassageResult.self, data: data, status: 200)
        XCTAssertEqual(r.replacement, "edited.")
    }

    func testFixStreamEvents() throws {
        XCTAssertEqual(FixEvent.parse(line: #"{"type":"status","stage":"researching","detail":"Searching for 2 claims"}"#), .status(stage: "researching", detail: "Searching for 2 claims"))
        XCTAssertEqual(FixEvent.parse(line: #"{"type":"error","message":"Nothing is flagged."}"#), .error("Nothing is flagged."))
        XCTAssertNil(FixEvent.parse(line: ""))
        let fixed = #"{"type":"fixed","content":"A corrected answer.","changes":[{"find":"wrong","replace":"right"}],"verification":{"claims":[{"claim":"right","verdict":"supported","citedBy":[1],"rationale":""}],"supported":1,"unsupported":0,"contradicted":0,"score":1},"sources":[{"index":1,"title":"S","url":"https://s.org"}],"queries":["q"],"newSources":1}"#
        guard case .fixed(let r)? = FixEvent.parse(line: fixed) else { return XCTFail("no fixed") }
        XCTAssertEqual(r.changes.count, 1)
        XCTAssertEqual(r.verification?.supported, 1)
        XCTAssertEqual(r.summary, "1 sentence rewritten from 1 new source")
    }
}

final class MonitorTests: XCTestCase {
    func testMonitorsDecode() throws {
        let data = Data(#"{"result":{"data":{"json":[{"id":"mon_1","userId":"u","workspaceId":null,"claimId":"c1","claim":"The UK bank rate is 4%.","baselineVerdict":"supported","baselineConfidence":0.8,"intervalDays":3,"active":true,"lastChecked":"2026-10-24T10:00:00Z","nextCheck":"2026-10-27T10:00:00Z","changedAt":"2026-10-24T10:00:00Z","changeNote":"The sources now contradict this. It was supported."}]}}}"#.utf8)
        let m = try TRPC.decode([Monitor].self, data: data, status: 200)
        XCTAssertTrue(m[0].hasChanged)
        XCTAssertEqual(m[0].intervalLine, "every 3 days")
        XCTAssertEqual(m[0].claimId, "c1")
    }

    func testCheckNowSummary() throws {
        let data = Data(#"{"result":{"data":{"json":{"checked":2,"changed":[{"monitorId":"mon_1","claim":"x","from":"supported","to":"contradicted","note":"The sources now contradict this."}],"notified":1}}}}"#.utf8)
        let r = try TRPC.decode(MonitorCheck.self, data: data, status: 200)
        XCTAssertEqual(r.summary, "1 of 2 changed. The sources now contradict this.")
        XCTAssertEqual(MonitorCheck(checked: 0).summary, "Nothing to check right now.")
        XCTAssertEqual(MonitorCheck(checked: 3).summary, "Checked 3. Nothing has changed.")
    }

    func testHookMayBeNull() throws {
        let none = Data(#"{"result":{"data":{"json":null}}}"#.utf8)
        XCTAssertNil(try TRPC.decode(MonitorHook?.self, data: none, status: 200))
        let some = Data(#"{"result":{"data":{"json":{"token":"tok","fires":2,"lastFired":null,"createdAt":"2026-10-01T00:00:00Z","url":"/api/monitors/hook/tok"}}}}"#.utf8)
        let hook = try XCTUnwrap(try TRPC.decode(MonitorHook?.self, data: some, status: 200))
        XCTAssertEqual(hook.fullURL().absoluteString, "https://helius-olo.io/api/monitors/hook/tok")
    }

    func testWatchInputOmitsInterval() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(OloAPI.WatchInput(claimId: "c1")), as: UTF8.self), #"{"claimId":"c1"}"#)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(OloAPI.MonitorIdInput(monitorId: nil)), as: UTF8.self), "{}")
    }
}

final class ZeusGraphTests: XCTestCase {
    func testGraphDecodesAndPlaces() throws {
        let data = Data(#"""
        {"result":{"data":{"json":{"nodes":[
          {"id":"c1","contributedBy":null,"claim":"Water boils at 100 C at sea level.","verdict":"supported","confidence":0.95,"supporting":4,"contradicting":0,"volatility":"stable","verifiedAt":"2026-10-01T00:00:00Z","expiresAt":null,"hitCount":3,"evidence":[{"url":"https://a.org/x","domain":"a.org","title":"A","provider":"tavily","stance":"supports"}]},
          {"id":"c2","contributedBy":null,"claim":"B","verdict":"contradicted","confidence":0.6,"supporting":0,"contradicting":2,"volatility":"slow","verifiedAt":"2026-10-01T00:00:00Z","expiresAt":null,"hitCount":0,"evidence":[]}
        ],"conflicts":[{"a":"c1","b":"c2","similarity":0.9}],"sources":[{"domain":"a.org","reputation":0.8,"total":5}],"stats":{"claims":2,"evidence":1,"conflicts":1,"recalled":3,"saved":3}}}}}
        """#.utf8)
        let g = try TRPC.decode(ZeusGraph.self, data: data, status: 200)
        XCTAssertEqual(g.nodes.count, 2)
        XCTAssertEqual(g.nodes[0].evidence[0].domain, "a.org")
        XCTAssertEqual(g.stats.saved, 3)
        let placed = GraphLayout.place(g.nodes, size: 320)
        XCTAssertEqual(placed.count, 2)
        for p in placed {
            XCTAssertGreaterThanOrEqual(p.x, 0); XCTAssertLessThanOrEqual(p.x, 320)
            XCTAssertGreaterThanOrEqual(p.y, 0); XCTAssertLessThanOrEqual(p.y, 320)
        }
        XCTAssertEqual(placed[0].r, 3 + 2 * 3, accuracy: 0.001)
        XCTAssertEqual(placed[1].r, 3, accuracy: 0.001)
        XCTAssertEqual(GraphLayout.hit(placed, x: placed[1].x + 2, y: placed[1].y)?.id, "c2")
        XCTAssertNil(GraphLayout.hit(placed, x: -100, y: -100))
    }

    func testEmptyGraph() throws {
        let data = Data(#"{"result":{"data":{"json":{"nodes":[],"conflicts":[],"sources":[],"stats":{"claims":0,"evidence":0,"conflicts":0,"recalled":0,"saved":0}}}}}"#.utf8)
        XCTAssertTrue(try TRPC.decode(ZeusGraph.self, data: data, status: 200).isEmpty)
    }
}

final class SkillsAndConnectorsTests: XCTestCase {
    func testSkillsDecode() throws {
        let data = Data(#"{"result":{"data":{"json":[{"id":"s1","userId":"u","name":"Board paper","description":"Writes board papers.","instructions":"Use headings.","triggers":["board"],"visibility":"private","status":"pending_review","flags":[{"rule":"External link","severity":"review","excerpt":"http"}],"uses":2,"createdAt":"2026-10-01T00:00:00Z"}]}}}"#.utf8)
        let s = try TRPC.decode([Skill].self, data: data, status: 200)
        XCTAssertEqual(s[0].statusLabel, "Waiting for review")
        XCTAssertFalse(s[0].isActive)
        XCTAssertEqual(s[0].flags[0].severity, "review")
        let created = Data(#"{"result":{"data":{"json":{"skill":{"id":"s2","name":"N","description":"d","instructions":"i","triggers":[],"visibility":"private","status":"active","flags":[],"uses":0,"createdAt":""},"message":"Saved."}}}}"#.utf8)
        XCTAssertEqual(try TRPC.decode(SkillCreated.self, data: created, status: 200).message, "Saved.")
    }

    func testConnectorsDecode() throws {
        let data = Data(#"{"result":{"data":{"json":{"available":true,"googleConfigured":true,"connections":[{"provider":"google","account":"me@example.com","scopes":["https://www.googleapis.com/auth/gmail.readonly","https://www.googleapis.com/auth/calendar.readonly"],"brokenReason":null,"lastUsedAt":null,"createdAt":"2026-10-01T00:00:00Z"}]}}}}"#.utf8)
        let c = try TRPC.decode(ConnectorList.self, data: data, status: 200)
        XCTAssertEqual(c.google?.account, "me@example.com")
        XCTAssertEqual(c.google?.scopesLine, "Gmail and Calendar, read only")
        XCTAssertEqual(LinkPolicy.parse(URL(string: "olo://connected")!), .connected)
    }
}

final class ComputeTests: XCTestCase {
    func testJobDecodesAndSummarises() throws {
        let data = Data(#"{"result":{"data":{"json":{"id":"job_1","userId":"u","conversationId":null,"prompt":"Analyse X","status":"running","progress":0.4,"stages":[{"id":"plan","label":"Planning","status":"done"},{"id":"run","label":"Reading sources","status":"running","detail":"3 of 8"}],"result":null,"error":null,"cancelRequested":false,"createdAt":"2026-10-25T09:00:00Z","updatedAt":"2026-10-25T09:01:00Z"}}}}"#.utf8)
        let j = try TRPC.decode(ComputeJob.self, data: data, status: 200)
        XCTAssertTrue(j.isRunning)
        XCTAssertEqual(j.fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(j.statusLine, "Running: Reading sources")
        XCTAssertEqual(ComputeJob(id: "x", prompt: "p", status: "failed", progress: 40, error: "Timed out").statusLine, "Failed: Timed out")
        XCTAssertEqual(ComputeJob(id: "x", prompt: "p", progress: 40).fraction, 0.4, accuracy: 0.001)
    }
}

final class ChartTests: XCTestCase {
    func testStrictParse() {
        XCTAssertNotNil(ChartSpec.parse(#"{"type":"bar","title":"Sales","x":["Q1","Q2"],"series":[{"name":"2025","values":[1,2]}],"y":"£m"}"#))
        XCTAssertNil(ChartSpec.parse(#"{"type":"pie","x":["a","b"],"series":[{"values":[1,2]}]}"#))
        XCTAssertNil(ChartSpec.parse(#"{"type":"bar","x":["a"],"series":[{"values":[1]}]}"#), "needs two points")
        XCTAssertNil(ChartSpec.parse(#"{"type":"bar","x":["a","b"],"series":[{"values":[1]}]}"#), "values must match x")
        XCTAssertNil(ChartSpec.parse(#"{"type":"bar","x":["a","b"],"series":[{"values":[1,"x"]}]}"#), "non numbers refused")
        XCTAssertNil(ChartSpec.parse("not json"))
        let spec = ChartSpec.parse(#"{"type":"line","x":[2024,2025],"series":[{"values":["1.5",2]}]}"#)!
        XCTAssertEqual(spec.x, ["2024", "2025"])
        XCTAssertEqual(spec.series[0].name, "Series 1")
        XCTAssertEqual(spec.series[0].values, [1.5, 2])
    }

    func testSegmentsKeepTextAroundCharts() {
        let content = "Sales grew.\n\n```chart\n{\"type\":\"bar\",\"x\":[\"a\",\"b\"],\"series\":[{\"name\":\"s\",\"values\":[1,2]}]}\n```\n\nThat is all.\n\n```chart\nbroken\n```"
        let segs = ChartBlocks.segments(of: content)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs[0], .text("Sales grew."))
        guard case .chart(let c) = segs[1] else { return XCTFail("chart") }
        XCTAssertEqual(c.type, "bar")
        XCTAssertEqual(segs[2], .text("That is all."))
        XCTAssertEqual(segs[3], .broken)
        XCTAssertEqual(ChartBlocks.textOnly(content), "Sales grew.\n\nThat is all.")
        XCTAssertEqual(ChartBlocks.segments(of: "plain"), [.text("plain")])
    }

    func testTicks() {
        XCTAssertEqual(ChartBlocks.niceStep(10), 5)
        XCTAssertEqual(ChartBlocks.niceStep(6), 2)
        XCTAssertEqual(ChartBlocks.niceStep(0.7), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ChartBlocks.formatTick(1500), "1.5k")
        XCTAssertEqual(ChartBlocks.formatTick(2_000_000), "2M")
        XCTAssertEqual(ChartBlocks.formatTick(120), "120")
        XCTAssertEqual(ChartBlocks.formatTick(2.0), "2")
        XCTAssertEqual(ChartBlocks.formatTick(0.25), "0.25")
    }
}

final class ExportAndFooterTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testMarkdownAndPlainText() {
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        let c = LocalConversation(serverId: 1, title: "Sargassum", turns: [
            Turn(role: .user, text: "Is sargassum a biofuel?", createdAt: when),
            Turn(role: .assistant, text: "It can be.", origin: .olo, verification: AnswerVerification(claims: [ClaimVerdict(claim: "It can be.", verdict: "supported", citedBy: [1])]),
                 sources: [Source(index: 1, title: "Study", url: "https://s.org/x")], createdAt: when, writer: "claude", provider: "anthropic", verifier: "zeus"),
        ])
        let md = TranscriptExport.markdown(c, folder: "Energy", timeZone: utc)
        XCTAssertTrue(md.hasPrefix("# Sargassum\n\nOlo. Checked by Zeus.\nStarted 14 October 2026 at 17:46\nFolder: Energy"))
        XCTAssertTrue(md.contains("**You** (14 October 2026 at 17:46)\n\nIs sargassum a biofuel?"))
        XCTAssertTrue(md.contains("Checked by Zeus: 1 supported, 0 contradicted, 0 not covered."))
        XCTAssertTrue(md.contains("1. [Study](https://s.org/x)"))
        XCTAssertTrue(md.contains("_Answered by claude via anthropic, checked by zeus_"))
        let txt = TranscriptExport.plainText(c, timeZone: utc)
        XCTAssertTrue(txt.hasPrefix("Olo. Checked by Zeus.\n=====================\n\nSargassum"))
        XCTAssertTrue(txt.contains(String(repeating: "-", count: 60)))
        XCTAssertEqual(TranscriptExport.blocks(c, timeZone: utc).count, 2)
        XCTAssertTrue(TranscriptExport.blocks(c, timeZone: utc)[1].body.contains("Sources: [1] Study"))
        for s in [md, txt] { XCTAssertFalse(s.contains("\u{2014}")); XCTAssertFalse(s.contains("\u{2013}")) }
    }

    func testSafeFilename() {
        XCTAssertEqual(TranscriptExport.safeFilename("What is: a/b?"), "What is a b")
        XCTAssertEqual(TranscriptExport.safeFilename("   "), "conversation")
        XCTAssertEqual(TranscriptExport.safeFilename(String(repeating: "x", count: 100)).count, 60)
    }

    func testReferencesLine() {
        let refs = [ReferenceCheck(text: "10.1/a", doi: "10.1/a", exists: true), ReferenceCheck(text: "b", exists: false, note: "no match in Crossref"),
                    ReferenceCheck(text: "c", exists: true, note: "retracted"), ReferenceCheck(text: "d", exists: nil, note: "not checked")]
        XCTAssertEqual(References.line(refs), "3 references checked, 1 not found, 1 retracted")
        XCTAssertEqual(References.flagged(refs).map(\.text), ["b", "c"])
        XCTAssertNil(References.line([ReferenceCheck(text: "d")]))
        XCTAssertNil(References.line(nil))
        XCTAssertEqual(References.line([ReferenceCheck(text: "a", exists: true)]), "1 reference checked, 0 not found")
    }

    func testReferencesAndMemoriesStreamEvents() {
        let refs = StreamEvent.parse(line: #"{"type":"references","references":[{"text":"10.1/a","doi":"10.1/a","exists":false,"title":null,"note":"no match in Crossref"}]}"#)
        XCTAssertEqual(refs, .references([ReferenceCheck(text: "10.1/a", doi: "10.1/a", exists: false, note: "no match in Crossref")]))
        let mem = StreamEvent.parse(line: #"{"type":"memories","memories":[{"id":"m1","category":"profile","content":"Runs a studio."}]}"#)
        XCTAssertEqual(mem, .memories([UsedMemory(id: "m1", category: "profile", content: "Runs a studio.")]))
        XCTAssertEqual(StreamEvent.parse(line: #"{"type":"truncated","jobId":null,"message":"Queued."}"#), .truncated(jobId: nil, message: "Queued."))
        var o = StreamOutcome()
        o.apply(refs!); o.apply(mem!)
        XCTAssertEqual(o.references.count, 1)
        XCTAssertEqual(o.memories.count, 1)
    }

    func testContextGauge() {
        let turns = (0..<30).map { i in (role: i % 2 == 0 ? "user" : "assistant", text: String(repeating: "x", count: 4000)) }
        let r = ContextGauge.reading(turns: turns, draft: "hello", tier: "medium")
        // 20 turns of 1000 tokens, plus 2000 for the system, plus 2 for the draft.
        XCTAssertEqual(r.tokens, 22_002)
        XCTAssertEqual(r.percent, 17)
        XCTAssertEqual(r.level, .ok)
        XCTAssertEqual(r.line, "about 17% of the context used")
        let big = ContextGauge.reading(turns: turns, draft: "", tier: "medium", windowTokens: 24_000)
        XCTAssertEqual(big.level, .danger)
        XCTAssertTrue(big.suggestSummary)
        XCTAssertEqual(ContextGauge.reading(turns: [], draft: "", windowTokens: 0).fraction, 1)
    }

    func testSourceTiersAndVerdictExtras() throws {
        let line = #"{"type":"sources","sources":[{"index":1,"title":"Forum","url":"https://www.reddit.com/r/x","provider":"tavily","urlOk":false,"published":null,"tier":4,"tierLabel":"user-generated"},{"index":2,"title":"Gov","url":"https://www.gov.uk/x","tier":1}]}"#
        guard case .sources(let s)? = StreamEvent.parse(line: line) else { return XCTFail("no sources") }
        XCTAssertEqual(s[0].downRankedLabel, "user-generated")
        XCTAssertEqual(s[0].urlOk, false)
        XCTAssertEqual(s[0].domain, "reddit.com")
        XCTAssertNil(s[1].downRankedLabel)
        let v = try JSONDecoder().decode(AnswerVerification.self, from: Data(#"{"claims":[{"claim":"A","claimId":"c1","verdict":"supported","citedBy":[1],"rationale":"","recalled":true}],"supported":1,"unsupported":0,"contradicted":0,"score":1,"references":[{"text":"x","doi":null,"exists":true,"title":"T","note":null}],"freshnessNote":"Old."}"#.utf8))
        XCTAssertEqual(v.claims[0].claimId, "c1")
        XCTAssertEqual(v.claims[0].recalled, true)
        XCTAssertEqual(v.references?.count, 1)
        XCTAssertEqual(v.freshnessNote, "Old.")
        XCTAssertEqual(v.flaggedCount, 0)
    }

    func testTurnsSavedByOlderVersionsStillDecode() throws {
        let old = Data(#"{"id":"6E1C7A2B-2B6D-4F0E-9E3C-5A1F2B3C4D5E","role":"assistant","text":"Hi","sources":[],"notices":[],"followUps":[],"attachments":[],"createdAt":"2026-10-24T10:00:00Z"}"#.utf8)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let t = try d.decode(Turn.self, from: old)
        XCTAssertEqual(t.text, "Hi")
        XCTAssertTrue(t.artifacts.isEmpty)
        XCTAssertTrue(t.references.isEmpty)
        XCTAssertNil(t.verification)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let again = try d.decode(Turn.self, from: try e.encode(Turn(role: .assistant, text: "x", artifacts: [Artifact(id: "a", kind: "code", title: "t", filename: "t.txt", code: "c")])))
        XCTAssertEqual(again.artifacts.first?.id, "a")
    }
}
