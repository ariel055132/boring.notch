//
//  CalendarMonth.swift
//  boringNotch
//

import Foundation

struct CalendarMonth {
    let calendar: Calendar
    let interval: DateInterval
    let days: [Date?]

    init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        // Calendar dates always have a containing month and a range of days.
        let monthInterval = calendar.dateInterval(of: .month, for: date)!
        interval = monthInterval
        let dayCount = calendar.range(of: .day, in: .month, for: date)!.count
        let leadingDays = (calendar.component(.weekday, from: monthInterval.start) - calendar.firstWeekday + 7) % 7
        let cellCount = ((leadingDays + dayCount + 6) / 7) * 7
        days = (0..<cellCount).map { index in
            guard (leadingDays..<(leadingDays + dayCount)).contains(index) else { return nil }
            return calendar.date(byAdding: .day, value: index - leadingDays, to: monthInterval.start)
        }
    }

    var weekCount: Int { days.count / 7 }

    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    func eventsByDay(
        from events: [EventModel], hideCompletedReminders: Bool, hideAllDayEvents: Bool
    ) -> [Date: [EventModel]] {
        let visibleEvents = events.filter { event in
            // Keep the existing setting semantics: all-day filtering applies to events,
            // while reminders are filtered by their completion state.
            if case .reminder(let completed) = event.type {
                return !completed || !hideCompletedReminders
            }
            return !event.isAllDay || !hideAllDayEvents
        }

        var result: [Date: [EventModel]] = [:]
        for date in days.compactMap({ $0 }) {
            guard let day = calendar.dateInterval(of: .day, for: date) else { continue }
            let dayEvents = visibleEvents.filter { event in
                if event.type.isReminder || event.end <= event.start {
                    return event.start >= day.start && event.start < day.end
                }
                // EventKit end dates are exclusive, including midnight for all-day events.
                return event.start < day.end && event.end > day.start
            }
            if !dayEvents.isEmpty {
                result[date] = dayEvents
            }
        }
        return result
    }
}
