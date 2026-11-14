import XCTest
@testable import OloKit

/// What the iPhone app works out from a calendar, on the device: the agenda, what is next, the
/// gaps, the habits it notices, and the only text that is ever shared with a question.
final class DayPlanTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    func event(_ title: String, _ day: Int, _ from: Int, _ to: Int, allDay: Bool = false) -> PlanEvent {
        PlanEvent(title: title, start: at(day, from), end: at(day, to), allDay: allDay)
    }

    func testAgendaPutsAllDayFirstAndKeepsOnlyThatDay() {
        let events = [event("Lunch", 16, 13, 14), event("Standup", 16, 9, 10), PlanEvent(title: "Birthday", start: at(16, 0), end: at(17, 0), allDay: true), event("Tomorrow", 17, 9, 10)]
        XCTAssertEqual(DayPlan.agenda(events, on: at(16, 12), calendar: cal).map(\.title), ["Birthday", "Standup", "Lunch"])
    }

    func testNextIsTheOneHappeningNowOrElseTheNextToStart() {
        let events = [event("Standup", 16, 9, 10), event("Review", 16, 11, 12)]
        XCTAssertEqual(DayPlan.next(events, after: at(16, 9, 30))?.title, "Standup")
        XCTAssertEqual(DayPlan.next(events, after: at(16, 10, 15))?.title, "Review")
        XCTAssertNil(DayPlan.next(events, after: at(16, 13)))
    }

    func testFreeBlocksAreTheGapsInTheWorkingDay() {
        let events = [event("Standup", 16, 9, 10), event("Review", 16, 11, 12), event("Call", 16, 12, 13)]
        let blocks = DayPlan.freeBlocks(events, on: at(16, 8), calendar: cal)
        XCTAssertEqual(blocks.map(\.minutes), [60, 300])
        XCTAssertEqual(blocks.first?.start, at(16, 10))
        // Never offers time that has already gone.
        XCTAssertEqual(DayPlan.freeBlocks(events, on: at(16, 8), now: at(16, 15), calendar: cal).map(\.minutes), [180])
        XCTAssertEqual(DayPlan.freeBlocks([], on: at(16, 8), calendar: cal).map(\.minutes), [540])
    }

    func testHabitsNoticeWhatKeepsHappening() {
        // Team sync on four Tuesdays (3, 10, 17, 24 November 2026) at ten; a scattering of other things.
        var past = [3, 10, 17, 24].map { event("Team sync", $0, 10, 11) }
        past += [event("Dentist", 4, 15, 16), event("Gym", 5, 8, 9), event("Planning", 10, 14, 15), event("Retro", 17, 15, 16)]
        let lines = DayPlan.habits(past, calendar: cal)
        XCTAssertEqual(lines.first, "Team sync: most Tuesdays around 10:00.")
        XCTAssertTrue(lines.contains("Tuesday is usually your fullest day."))
        XCTAssertTrue(lines.contains("Your days usually start around 10:00."))
        XCTAssertEqual(DayPlan.habits([], calendar: cal), [])
    }

    func testTheBriefArrivesAnHourBeforeTheDayUsuallyStarts() {
        let past = [3, 4, 5, 6].map { event("Standup", $0, 9, 10) }
        XCTAssertEqual(DayPlan.briefHour(past, calendar: cal), 8)
        XCTAssertEqual(DayPlan.briefHour([], calendar: cal), 8)
        XCTAssertEqual(DayPlan.briefHour([3, 4, 5].map { event("Late", $0, 14, 15) }, calendar: cal), 10)
    }

    func testTheBriefAndTheSharedTextSayOnlyWhatIsInTheCalendar() {
        let events = [event("Standup", 16, 9, 10), event("Review", 16, 11, 12)]
        XCTAssertEqual(DayPlan.brief(for: at(16, 7), events: events, calendar: cal),
                       "2 things in your calendar today. First: Standup at 09:00. Your longest free stretch is 12:00 to 18:00.")
        XCTAssertEqual(DayPlan.brief(for: at(18, 7), events: events, calendar: cal), "Nothing in your calendar today. The day is yours.")
        XCTAssertEqual(DayPlan.shareText(day: at(16, 7), events: events, calendar: cal),
                       "My calendar today:\n- 09:00 to 10:00: Standup\n- 11:00 to 12:00: Review")
        XCTAssertEqual(DayPlan.shareText(day: at(18, 7), events: events, calendar: cal), "My calendar today is empty.")
    }
}
