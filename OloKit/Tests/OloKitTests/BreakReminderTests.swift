import XCTest
@testable import OloKit

final class BreakReminderTests: XCTestCase {
    func testABreakIsDueAfterTwoHoursInFront() {
        let start = Date(timeIntervalSince1970: 0)
        var r = BreakReminder(now: start)
        for m in 1...119 { r.tick(now: start.addingTimeInterval(Double(m) * 60), visible: true) }
        XCTAssertFalse(r.isDue)
        r.tick(now: start.addingTimeInterval(120 * 60), visible: true)
        XCTAssertTrue(r.isDue)
    }

    func testTimeAwayDoesNotCountAndThirtyMinutesStartsAgain() {
        let start = Date(timeIntervalSince1970: 0)
        var r = BreakReminder(now: start)
        for m in 1...30 { r.tick(now: start.addingTimeInterval(Double(m) * 60), visible: true) }
        r.tick(now: start.addingTimeInterval(35 * 60), visible: false)
        XCTAssertEqual(r.active, 30 * 60)
        r.tick(now: start.addingTimeInterval(30 * 60 + BreakReminder.awayResets), visible: true)
        XCTAssertEqual(r.active, 0)
        r.nudged(now: start)
        XCTAssertFalse(r.isDue)
        XCTAssertEqual(BreakReminder.message, "Call a friend or connect with nature. Don't lose your humanity.")
    }
}
