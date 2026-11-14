import XCTest
@testable import OloKit

final class SchedulesTests: XCTestCase {
    func testScheduledTasksDecode() throws {
        let data = Data(##"{"result":{"data":{"json":[{"id":7,"userId":"u","title":"Ocean fact","prompt":"Give me one verified fact about the ocean.","cadence":"weekdays","hour":7,"minute":30,"weekday":null,"timeZone":"Europe/London","grounded":true,"email":true,"enabled":true,"conversationId":42,"nextRunAt":"2026-11-05T07:30:00.000Z","lastRunAt":"2026-11-04T07:30:00.000Z","lastStatus":"ok","lastSummary":"The Pacific is the largest ocean.","runs":3,"createdAt":"2026-11-01T00:00:00Z","label":"Weekdays at 07:30"}]}}}"##.utf8)
        let tasks = try TRPC.decode([ScheduledTask].self, data: data, status: 200)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].scheduleLine, "Weekdays at 07:30")
        XCTAssertEqual(tasks[0].conversationId, 42)
        XCTAssertEqual(tasks[0].lastLine, "The Pacific is the largest ocean.")
        XCTAssertTrue(tasks[0].email)
    }

    func testScheduleLineWithoutLabelAndLastLines() {
        let weekly = ScheduledTask(id: 1, title: "t", prompt: "p", cadence: "weekly", hour: 18, minute: 0, weekday: 5)
        XCTAssertEqual(weekly.scheduleLine, "Fridays at 18:00")
        XCTAssertEqual(ScheduledTask(id: 2, title: "t", prompt: "p", hour: 8, minute: 5).scheduleLine, "Every day at 08:05")
        XCTAssertNil(weekly.lastLine)
        let quota = ScheduledTask(id: 3, title: "t", prompt: "p", lastStatus: "quota", lastSummary: "That is your 5 free messages.")
        XCTAssertEqual(quota.lastLine, "Not run: message allowance used. That is your 5 free messages.")
    }

    func testInputDropsWeekdayUnlessWeekly() throws {
        let daily = ScheduleInput(prompt: "p", cadence: "daily", hour: 8, minute: 0, weekday: 3, timeZone: "Europe/London")
        XCTAssertNil(daily.weekday)
        let json = String(data: try JSONEncoder().encode(ScheduleInput(prompt: "p", cadence: "weekly", hour: 9, minute: 0, weekday: 1, timeZone: "UTC", email: true)), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"weekday\":1"))
        XCTAssertTrue(json.contains("\"email\":true"))
    }

    func testScheduledNudgeOpensItsConversation() {
        let n = Nudge(id: "n1", kind: "scheduled_answer", subjectId: "42", title: "Ocean fact", body: "The Pacific...")
        XCTAssertEqual(n.conversationId, 42)
        XCTAssertNil(Nudge(id: "n2", kind: "claim_changed", subjectId: "c1", title: "x", body: "y").conversationId)
    }
}
