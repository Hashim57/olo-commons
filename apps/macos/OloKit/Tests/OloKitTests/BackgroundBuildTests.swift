import XCTest
@testable import OloKit

/// Background builds as the Mac now follows them: which requests go straight to the background,
/// and what the build card reads from a v63 job (steps, who is writing, the clock).
final class BackgroundBuildTests: XCTestCase {
    func testWholeProductsGoToTheBackgroundAndSmallPiecesStream() {
        XCTAssertTrue(BuildRouting.runsInBackground("please build a website on all dog breeds that ever existed"))
        XCTAssertTrue(BuildRouting.runsInBackground("Make me a landing page for a bakery"))
        XCTAssertTrue(BuildRouting.runsInBackground("i need you to build the literal website i can deploy on netlify"))
        XCTAssertTrue(BuildRouting.runsInBackground("Write a complete guide to UK employment law for startups"))
        XCTAssertFalse(BuildRouting.runsInBackground("Write a function that reverses a string"))
        XCTAssertFalse(BuildRouting.runsInBackground("Create a React button component with a loading state"))
        XCTAssertFalse(BuildRouting.runsInBackground("What is the sun made of?"))
        XCTAssertFalse(BuildRouting.runsInBackground("How many dog breeds are there?"))
    }

    func testAJobDecodesItsStepsAndWhoIsWriting() throws {
        let json = #"""
        {"id":"j1","status":"running","progress":41,"stage":"writing","detail":"Writing the file · 14 KB, 312 lines so far",
         "startedAt":"2026-11-03T21:00:00.000Z","createdAt":"2026-11-03T20:59:58.000Z",
         "answeredBy":{"writer":"Olo's backup model","writer_provider":"Groq","verifier":null,"mode":"olo"},
         "steps":[{"stage":"planning","detail":"Reading the request","at":"2026-11-03T21:00:00.000Z"},
                  {"stage":"writing","detail":"Olo's main model is unavailable, so Groq is writing the file.","at":"2026-11-03T21:00:03.000Z"},
                  {"stage":"writing","detail":"Writing the file · 14 KB, 312 lines so far","at":"2026-11-03T21:00:04.000Z"},
                  {"stage":"writing","detail":"Writing the file · 14 KB, 312 lines so far","at":"2026-11-03T21:00:06.000Z"}]}
        """#
        let job = try JSONDecoder().decode(BuildJob.self, from: Data(json.utf8))
        XCTAssertTrue(job.isRunning)
        XCTAssertEqual(job.headline, "Building in the background")
        XCTAssertEqual(job.answeredBy?.line, "Answered by Olo's backup model via Groq")
        let rows = job.timeline
        XCTAssertEqual(rows.map(\.label), ["Reading the request", "Olo's main model is unavailable, so Groq is writing the file.", "Writing the file · 14 KB, 312 lines so far"])
        XCTAssertEqual(rows.map(\.notice), [false, true, false])
        XCTAssertEqual(rows.last?.state, .current)
        XCTAssertEqual(rows[1].offset, 3)
        let now = BuildJob.date("2026-11-03T21:04:12.000Z")!
        XCTAssertEqual(job.elapsed(now: now).map(BuildTimelineRow.clock), "4:12")
    }

    func testAFinishedOrFailedJobReadsSo() throws {
        let done = try JSONDecoder().decode(BuildJob.self, from: Data(#"{"id":"j2","status":"succeeded","progress":100,"artifact":{"id":"a1","kind":"html","title":"Dogs","filename":"dogs.html","code":"<h1>x</h1>","answeredBy":{"writer":"Olo","writer_provider":"","verifier":null,"mode":"olo"}},"steps":[{"stage":"done","detail":"dogs.html is ready","at":"2026-11-03T21:02:00Z"}]}"#.utf8))
        XCTAssertEqual(done.headline, "Olo built dogs.html")
        XCTAssertEqual(done.answeredBy?.writer, "Olo", "older servers carry the record on the artifact")
        XCTAssertEqual(done.timeline.last?.state, .done)
        let failed = try JSONDecoder().decode(BuildJob.self, from: Data(#"{"id":"j3","status":"failed","progress":100,"error":"x","steps":[{"stage":"writing","detail":"Reading the request","at":"2026-11-03T21:00:00Z"}]}"#.utf8))
        XCTAssertEqual(failed.headline, "The build did not finish")
        XCTAssertEqual(failed.timeline.last?.state, .failed)
        // An old server's job, with none of the new fields, still decodes.
        let old = try JSONDecoder().decode(BuildJob.self, from: Data(#"{"id":"j4","status":"queued"}"#.utf8))
        XCTAssertTrue(old.steps.isEmpty)
        XCTAssertNil(old.answeredBy)
        XCTAssertEqual(BuildTimelineRow.clock(48), "0:48")
    }

    func testAFailedBuildCanBeAskedForAgainAndNamesNoWriter() throws {
        let json = #"""
        {"id":"j2","status":"failed","progress":100,"mode":"artifact","prompt":"build me a website on all dog breeds",
         "error":"None of Olo's writers answered, after three tries through all of them.",
         "answeredBy":{"writer":"Olo","writer_provider":"","verifier":null,"mode":"olo"},
         "steps":[{"stage":"writing","detail":"No writer answered, trying the chain again","at":"2026-11-03T21:00:00.000Z"}]}
        """#
        let job = try JSONDecoder().decode(BuildJob.self, from: Data(json.utf8))
        XCTAssertTrue(job.canRetry)
        XCTAssertEqual(job.prompt, "build me a website on all dog breeds")
        XCTAssertNil(job.finishedAnsweredBy)
        XCTAssertTrue(job.timeline[0].notice)
        var done = job
        done.status = "succeeded"
        XCTAssertFalse(done.canRetry)
        XCTAssertEqual(done.finishedAnsweredBy?.writer, "Olo")
        var answer = job
        answer.mode = "answer"
        XCTAssertFalse(answer.canRetry)
    }

    func testHalfAFileIsDroppedFromTheThread() {
        let cut = "A literal every breed is a few hundred.\n\n```html\n<!DOCTYPE html>\n<html><head>"
        XCTAssertTrue(ReplyFile.endsInsideFence(cut))
        XCTAssertEqual(ReplyFile.proseBeforeOpenFence(cut), "A literal every breed is a few hundred.")
        let whole = "Here:\n```html\n<p>x</p>\n```\nDone."
        XCTAssertFalse(ReplyFile.endsInsideFence(whole))
        XCTAssertEqual(ReplyFile.proseBeforeOpenFence(whole), whole)
    }
}
