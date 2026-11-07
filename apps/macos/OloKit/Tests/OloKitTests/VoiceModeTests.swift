import XCTest
@testable import OloKit

final class VoiceModeTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(VoiceMode.command("stop"), .stop)
        XCTAssertEqual(VoiceMode.command("That's all for now."), .stop)
        XCTAssertEqual(VoiceMode.command("Thanks Olo, goodbye"), .stop)
        XCTAssertEqual(VoiceMode.command("okay olo stop listening"), .stop)
        XCTAssertEqual(VoiceMode.command("Why did the bus stop?"), .ask("Why did the bus stop?"))
        XCTAssertEqual(VoiceMode.command("Build me a landing page for a bakery in Leeds."), .build("Build me a landing page for a bakery in Leeds"))
        XCTAssertEqual(VoiceMode.command("Can you make a quiz app about rivers"), .build("Can you make a quiz app about rivers"))
        XCTAssertEqual(VoiceMode.command("Create a document summarising the meeting"), .build("Create a document summarising the meeting"))
        XCTAssertEqual(VoiceMode.command("Make sense of this for me"), .ask("Make sense of this for me"))
        XCTAssertEqual(VoiceMode.command("build confidence before an exam"), .ask("build confidence before an exam"))
    }

    func testSentenceStream() {
        let s = SentenceStream(pieceChars: 60)
        XCTAssertEqual(s.push("The tide is pulled by the moon"), [])
        XCTAssertEqual(s.push("The tide is pulled by the moon. It rises twice a day in most places, about 12"), ["The tide is pulled by the moon."])
        XCTAssertEqual(s.push("The tide is pulled by the moon. It rises twice a day in most places, about 12.4 hours apart"), [])
        XCTAssertEqual(s.push("The tide is pulled by the moon. It rises twice a day in most places, about 12.4 hours apart. Spring tides are bigger. Neap tides are smaller. "),
                       ["It rises twice a day in most places, about 12.4 hours apart."])
        XCTAssertEqual(s.flush("The tide is pulled by the moon. It rises twice a day in most places, about 12.4 hours apart. Spring tides are bigger. Neap tides are smaller. The end"),
                       ["Spring tides are bigger. Neap tides are smaller. The end"])
    }

    func testCodeBlockIsNeverHalfSpoken() {
        let c = SentenceStream()
        XCTAssertEqual(c.push("Here is the code. ```js\nconst a = 1."), [])
        XCTAssertEqual(c.push("Here is the code. ```js\nconst a = 1.\n``` That prints one. "), ["Here is the code."])
        XCTAssertEqual(c.flush("Here is the code. ```js\nconst a = 1.\n``` That prints one. "), ["Code omitted. That prints one."])
    }

    func testBuildWords() {
        XCTAssertTrue(VoiceMode.buildDone(summary: "**A page** with three sections.", filename: "bakery.html").hasPrefix("bakery.html is ready. A page with three sections."))
        XCTAssertTrue(VoiceMode.buildFailed(error: nil).hasPrefix("That build did not finish."))
    }
}
