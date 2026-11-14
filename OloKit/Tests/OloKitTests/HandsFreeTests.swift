import XCTest
@testable import OloKit

final class ShakeTests: XCTestCase {
    /// Feeds readings of total acceleration (in g, along one axis) at the given times; returns the times a shake fired.
    private func run(_ readings: [(Double, Double)], _ detector: inout ShakeDetector) -> [Double] {
        var fired: [Double] = []
        for (t, g) in readings where detector.push(x: 0, y: 0, z: g, timeMs: t) { fired.append(t) }
        return fired
    }

    private func run(_ readings: [(Double, Double)]) -> [Double] {
        var d = ShakeDetector()
        return run(readings, &d)
    }

    func testDefaultsAndMagnitude() {
        XCTAssertEqual(ShakeOptions.defaults, ShakeOptions(thresholdG: 2.3, windowMs: 600, cooldownMs: 1500))
        XCTAssertEqual(ShakeDetector.magnitude(3, 4, 0), 5, accuracy: 1e-9)
    }

    func testWhatIsNotAShake() {
        XCTAssertEqual(run((0..<100).map { (Double($0) * 50, 1.0) }), [], "resting on a table never fires")
        XCTAssertEqual(run([(0, 1), (50, 3), (100, 1), (150, 1)]), [], "one hard bump does not fire")
        XCTAssertEqual(run([(0, 1), (50, 3), (100, 3.2), (150, 2.9), (200, 1)]), [], "a peak lasting several readings counts once")
        XCTAssertEqual(run([(0, 1), (100, 3), (200, 1), (800, 3), (900, 1)]), [], "two peaks 700 ms apart do not fire")
        XCTAssertEqual(run([(0, 1), (50, 2.3), (100, 1), (150, 2.3)]), [], "exactly 2.3 g is not above the threshold")
        var d = ShakeDetector()
        XCTAssertFalse(d.push(x: .nan, y: 0, z: 0, timeMs: 0), "bad readings are ignored")
    }

    func testShakes() {
        XCTAssertEqual(run([(0, 1), (50, 3), (100, 1), (350, 3), (400, 1)]), [350], "two peaks 300 ms apart fire")
        XCTAssertEqual(run([(0, 1), (100, 3), (200, 1), (700, 3)]), [700], "two peaks 600 ms apart still fire")
        var d = ShakeDetector()
        XCTAssertFalse(d.push(x: 0, y: 0, z: 1, timeMs: 0))
        XCTAssertFalse(d.push(x: 1.5, y: 1.5, z: 1.2, timeMs: 50))   // about 2.45 g
        XCTAssertFalse(d.push(x: 0, y: 0, z: 1, timeMs: 100))
        XCTAssertTrue(d.push(x: -1.5, y: -1.5, z: 1.2, timeMs: 200), "a diagonal shake counts the whole vector")
    }

    func testCooldownAndReset() {
        var long: [(Double, Double)] = []
        var t = 0.0
        while t < 3000 { long.append((t, Int(t / 50) % 2 == 0 ? 3 : 1)); t += 50 }
        let fired = run(long)
        XCTAssertEqual(fired.count, 2, "a long shake fires, then waits out the cooldown")
        if fired.count == 2 { XCTAssertGreaterThanOrEqual(fired[1] - fired[0], 1500) }

        var d = ShakeDetector()
        _ = run([(0, 3), (50, 1)], &d)
        d.reset()
        XCTAssertEqual(run([(100, 3), (150, 1)], &d), [], "reset forgets a half-finished shake")
    }
}

final class WakePhraseTests: XCTestCase {
    func testNormalise() {
        XCTAssertEqual(WakePhrase.normalize("Hey, Olo's  Answer?"), "hey olos answer")
        XCTAssertEqual(WakePhrase.normalize("Héllo  Ólo"), "hello olo")
    }

    func testWakes() {
        let wakes = ["Hey Olo", "hey olo", "Hey, Olo.", "hey oh low what time is it", "Hey O low", "Hello Olo", "hello, olo!", "Hi Olo", "OK Olo",
                     "hey ollo", "Hey-Olo, what is the capital of Peru?", "so I said hey olo can you help", "heyolo", "Hey Ola, what is the time",
                     "hey alo", "Hey Aloe", "hey oh la", "Hailo", "hiya olo"]
        for text in wakes { XCTAssertTrue(WakePhrase.contains(text), "wakes on \"\(text)\"") }
    }

    func testStaysAsleep() {
        let silent = ["", "hello", "hey look at this", "I went solo", "hey hollow knight", "the flight to Oslo", "olo is a nice name", "hey, hello there",
                      "hello low prices", "they told me", "a lot of people", "I said hola", "the aloe vera plant"]
        for text in silent { XCTAssertFalse(WakePhrase.contains(text), "stays asleep on \"\(text)\"") }
    }

    func testQuestionAfterWake() {
        XCTAssertNil(WakePhrase.questionAfterWake("what is the weather"))
        XCTAssertEqual(WakePhrase.questionAfterWake("Hey Olo"), "")
        XCTAssertEqual(WakePhrase.questionAfterWake("Hey Olo, what is the capital of Peru?"), "what is the capital of Peru?")
        XCTAssertEqual(WakePhrase.questionAfterWake("hey oh low how tall is Everest"), "how tall is Everest")
        XCTAssertEqual(WakePhrase.questionAfterWake("hello Olo Who wrote Hamlet"), "Who wrote Hamlet")
        XCTAssertEqual(WakePhrase.questionAfterWake("Hey-Olo when was the Magna Carta signed?"), "when was the Magna Carta signed?")
        XCTAssertEqual(WakePhrase.questionAfterWake("ok so hey olo what is 2 plus 2"), "what is 2 plus 2")
        XCTAssertEqual(WakePhrase.questionAfterWake("hey olo never mind hey olo what is pi"), "what is pi")
        XCTAssertEqual(WakePhrase.match("well hey olo")?.phrase, "hey olo")
    }

    func testRecognitionLanguage() {
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-US"), "en-US")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en_GB"), "en-GB")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-in"), "en-IN")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en"), "en-US")
        let ios = ["en-US", "en-GB", "en-IN", "en-AU", "en-IE", "de-DE", "fr-FR"]
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-DE", supported: ios), "en-GB")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en_DE"), "en-GB")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-BR", supported: ios), "en-US")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-IE", supported: ios), "en-IE")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "de-DE", supported: ios), "en-GB")
        XCTAssertEqual(WakePhrase.recognitionLanguage(deviceLocale: "en-DE", supported: ["en-US"]), "en-US")
    }

    func testCleanQuestionAndLetsTalk() {
        XCTAssertEqual(WakePhrase.cleanQuestion("I'm listening what is the capital of Peru"), "what is the capital of Peru")
        XCTAssertEqual(WakePhrase.cleanQuestion(" I am listening. how tall is Everest"), "how tall is Everest")
        XCTAssertEqual(WakePhrase.cleanQuestion("Go ahead, I'm listening. What time is it in Tokyo"), "What time is it in Tokyo")
        XCTAssertEqual(WakePhrase.cleanQuestion("go ahead how far is the moon"), "how far is the moon")
        XCTAssertEqual(WakePhrase.cleanQuestion("who is listening to this podcast"), "who is listening to this podcast")
        XCTAssertTrue(WakePhrase.wantsConversation("Let's talk"))
        XCTAssertTrue(WakePhrase.wantsConversation("lets have a chat about tides"))
        XCTAssertFalse(WakePhrase.wantsConversation("what is talk radio"))
    }

    func testVoiceEntry() {
        XCTAssertEqual(VoiceEntry.parse(URL(string: "olo://talk")!), .talk)
        XCTAssertEqual(VoiceEntry.parse(URL(string: "olo://ask?listen=1")!), .quickAsk)
        XCTAssertEqual(VoiceEntry.parse(URL(string: "olo://quickask")!), .quickAsk)
        XCTAssertNil(VoiceEntry.parse(URL(string: "olo://ask?q=hello")!))
        XCTAssertNil(VoiceEntry.parse(URL(string: "olo://chat/42")!))
        XCTAssertNil(VoiceEntry.parse(URL(string: "https://helius-olo.io/talk")!))
    }
}

final class WakeTrackerTests: XCTestCase {
    func testWakeThenQuestion() {
        var t = WakeTracker()
        XCTAssertEqual(t.heard("the kettle is on"), [])
        XCTAssertEqual(t.heard("the kettle is on hey olo"), [.woke, .question("")])
        XCTAssertEqual(t.phase, .capturing)
        XCTAssertEqual(t.heard("the kettle is on hey olo what is the tide"), [.question("what is the tide")])
        t.rearm()
        XCTAssertEqual(t.phase, .waiting)
        XCTAssertEqual(t.heard("the kettle is on hey olo what is the tide and so on"), [], "the old question is behind the offset")
    }

    func testAfterTheCue() {
        var t = WakeTracker()
        _ = t.heard("hey olo")
        t.beginAck()
        XCTAssertEqual(t.heard("hey olo go ahead"), [], "nothing counts while Olo says the cue")
        t.ackFinished()
        XCTAssertEqual(t.heard("hey olo go ahead I'm listening how far is the moon"), [.question("how far is the moon")])
    }

    func testDeafWhileOloSpeaks() {
        var t = WakeTracker()
        XCTAssertEqual(t.heard("hey olo what is pi", deaf: true), [])
        t.speechEnded()
        XCTAssertEqual(t.heard("hey olo what is pi and more"), [], "Olo never hears itself")
        XCTAssertEqual(t.heard("hey olo what is pi and more hey olo again"), [.woke, .question("again")])
    }

    func testAmbientTalkIsSkippedNotKept() {
        var t = WakeTracker()
        let chatter = String(repeating: "people talking about the weather ", count: 12)
        XCTAssertEqual(t.heard(chatter), [])
        XCTAssertGreaterThan(t.offset, 0)
        XCTAssertEqual(t.heard(chatter + "hey olo what time is it"), [.woke, .question("what time is it")])
        var long = WakeTracker()
        let much = String(repeating: "television in the background ", count: 100)
        XCTAssertEqual(long.heard(much), [.recycle])
        XCTAssertEqual(long.heard(much, canRecycle: false), [])
    }

    func testShorterTranscriptStartsOver() {
        var t = WakeTracker()
        _ = t.heard(String(repeating: "word ", count: 80))
        XCTAssertEqual(t.heard("hey olo hi"), [.woke, .question("hi")])
    }
}
