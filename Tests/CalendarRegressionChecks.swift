import Cocoa
import Foundation
@testable import Boring_Notch

@MainActor
enum CalendarRegressionChecks {
    static func run() -> Int {

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1

        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, calendar suppliedCalendar: Calendar? = nil) -> Date {
            (suppliedCalendar ?? calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }

        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let modelCalendar = CalendarModel(
            id: "test", account: "test", title: "Test", color: .systemBlue,
            isSubscribed: false, isReminder: false
        )

        func event(
            _ id: String, _ start: Date, _ end: Date,
            allDay: Bool = false, type: EventType = .event(.accepted)
        ) -> EventModel {
            EventModel(
                id: id, start: start, end: end, title: id,
                location: nil, notes: nil, url: nil, isAllDay: allDay,
                type: type, calendar: modelCalendar, participants: [],
                timeZone: nil, hasRecurrenceRules: false, priority: nil
            )
        }

        let leap = CalendarMonth(containing: date(2024, 2, 15), calendar: calendar)
        check(leap.days.compactMap { $0 }.count == 29, "Leap February must contain 29 days")
        check(leap.days.compactMap { $0 }.last == date(2024, 2, 29), "Leap day must be selectable")
        let fourWeeks = CalendarMonth(containing: date(2026, 2, 1), calendar: calendar)
        check(fourWeeks.weekCount == 4, "February 2026 fits four Sunday-first weeks")
        let month = CalendarMonth(containing: date(2026, 8, 31), calendar: calendar)
        check(month.weekCount == 6, "August 2026 needs six weeks")
        check(month.days.firstIndex { $0 != nil } == 6, "August starts in the Saturday column")
        check(month.days.compactMap { $0 }.count == 31, "Six-week layout must not lose month-end dates")
        check(month.interval.end == date(2026, 9, 1), "Query ends at next month, exclusively")

        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let mondayMonth = CalendarMonth(containing: date(2026, 8, 1), calendar: mondayCalendar)
        check(mondayMonth.days.firstIndex { $0 != nil } == 5, "Respect Monday-first calendars")
        check(mondayMonth.weekdaySymbols.first == "M", "Weekday heading matches first weekday")
        let december = CalendarMonth(containing: date(2026, 12, 31), calendar: calendar)
        check(december.interval.end == date(2027, 1, 1), "December query must cross the year boundary")

        let events = [
            event("cross-month", date(2026, 7, 31, 23), date(2026, 8, 2)),
            event("all-day", date(2026, 8, 3), date(2026, 8, 5), allDay: true),
            event("overnight", date(2026, 8, 5, 23), date(2026, 8, 6, 1)),
            event("instant", date(2026, 8, 7), date(2026, 8, 7)),
            event("completed", date(2026, 8, 8, 9), date(2026, 8, 9), type: .reminder(completed: true)),
            event("reminder", date(2026, 8, 9), date(2026, 8, 10), allDay: true, type: .reminder(completed: false)),
            event("recurring", date(2026, 8, 10, 9), date(2026, 8, 10, 10)),
            event("recurring", date(2026, 8, 17, 9), date(2026, 8, 17, 10)),
            event("next-month", date(2026, 9, 1), date(2026, 9, 2), type: .reminder(completed: false))
        ]
        let byDay = month.eventsByDay(from: events, hideCompletedReminders: true, hideAllDayEvents: false)
        check(byDay[date(2026, 8, 1)]?.map(\.id) == ["cross-month"], "Carry-in events mark the first day")
        check(byDay[date(2026, 8, 2)] == nil, "An event ending at midnight must not mark the following day")
        check(byDay[date(2026, 8, 3)]?.map(\.id) == ["all-day"], "All-day event marks its start")
        check(byDay[date(2026, 8, 4)]?.map(\.id) == ["all-day"], "All-day event marks intermediate days")
        check(byDay[date(2026, 8, 5)]?.map(\.id) == ["overnight"], "All-day end is exclusive")
        check(byDay[date(2026, 8, 6)]?.map(\.id) == ["overnight"], "Overnight timed events mark both days")
        check(byDay[date(2026, 8, 7)]?.map(\.id) == ["instant"], "Zero-duration events still have a dot")
        check(byDay[date(2026, 8, 8)] == nil, "Completed reminders are hidden from dots and lists")
        check(byDay[date(2026, 8, 9)]?.map(\.id) == ["reminder"], "Undated-time reminders use their due day")
        check(byDay[date(2026, 8, 10)]?.count == 1, "Reminders do not spill into the next day")
        check(byDay[date(2026, 8, 17)]?.map(\.id) == ["recurring"], "Recurring instances with shared IDs are retained")
        check(byDay[date(2026, 9, 1)] == nil, "Next-month reminders do not belong to this month")
        let hiddenAllDay = month.eventsByDay(from: events, hideCompletedReminders: true, hideAllDayEvents: true)
        check(hiddenAllDay[date(2026, 8, 3)] == nil, "Hide all-day events removes their dots")
        check(hiddenAllDay[date(2026, 8, 9)]?.count == 1, "All-day filtering preserves existing reminder behavior")
        let showCompleted = month.eventsByDay(from: events, hideCompletedReminders: false, hideAllDayEvents: false)
        check(showCompleted[date(2026, 8, 8)]?.map(\.id) == ["completed"], "Completion filter is reversible")

        var dstCalendar = calendar
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstMonth = CalendarMonth(containing: date(2026, 3, 8, calendar: dstCalendar), calendar: dstCalendar)
        let dstStart = date(2026, 3, 8, calendar: dstCalendar)
        let dstEnd = date(2026, 3, 9, calendar: dstCalendar)
        check(dstEnd.timeIntervalSince(dstStart) == 23 * 3600, "Fixture covers a 23-hour DST day")
        let dstEvents = dstMonth.eventsByDay(
            from: [event("DST", dstStart, dstEnd, allDay: true)],
            hideCompletedReminders: true, hideAllDayEvents: false
        )
        check(dstEvents[dstStart]?.count == 1 && dstEvents[dstEnd] == nil, "DST must not shift day boundaries")
        check(Set(dstMonth.days.compactMap { $0 }).count == 31, "DST month contains 31 distinct selectable days")

        return checks
    }
}
