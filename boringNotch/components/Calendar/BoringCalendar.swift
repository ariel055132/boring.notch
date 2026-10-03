//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.hideCompletedReminders) private var hideCompletedReminders
    @Default(.hideAllDayEvents) private var hideAllDayEvents
    @State private var displayedMonth = Date()
    @State private var selectedDate: Date?
    @State private var monthEvents: [EventModel] = []
    @State private var loadedRequest: MonthRequest?
    @State private var refreshID = 0
    @State private var haptics = false

    private struct MonthRequest: Equatable {
        let month: Date
        let revision: Int
        let refreshID: Int
    }

    private var month: CalendarMonth { CalendarMonth(containing: displayedMonth) }

    private var request: MonthRequest {
        MonthRequest(
            month: month.interval.start,
            revision: calendarManager.eventsRevision,
            refreshID: refreshID
        )
    }

    var body: some View {
        let isLoading = loadedRequest != request
        let eventsByDay = month.eventsByDay(
            from: isLoading ? [] : monthEvents,
            hideCompletedReminders: hideCompletedReminders,
            hideAllDayEvents: hideAllDayEvents
        )

        VStack(spacing: 0) {
            if let selectedDate {
                dayView(
                    date: selectedDate,
                    events: eventsByDay[selectedDate] ?? [],
                    isLoading: isLoading
                )
            } else {
                MonthCalendarView(
                    month: month,
                    eventDays: Set(eventsByDay.keys),
                    onSelectDate: { date in
                        self.selectedDate = date
                        if Defaults[.enableHaptics] {
                            haptics.toggle()
                        }
                    },
                    onChangeMonth: changeMonth,
                    onShowCurrentMonth: showCurrentMonth
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sensoryFeedback(.alignment, trigger: haptics)
        .task(id: request) {
            let currentRequest = request
            let events = await calendarManager.events(in: month.interval)
            // A rapid month change or an EventKit refresh can cancel an older query.
            guard !Task.isCancelled else { return }
            monthEvents = events
            loadedRequest = currentRequest
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .open {
                showCurrentMonth()
            }
        }
    }

    private func dayView(date: Date, events: [EventModel], isLoading: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    selectedDate = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to month")
                .accessibilityLabel("Back to month")

                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .frame(height: 18)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                EmptyEventsView(selectedDate: date)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EventListView(events: events)
            }
        }
    }

    private func changeMonth(by offset: Int) {
        if let date = month.calendar.date(byAdding: .month, value: offset, to: month.interval.start) {
            displayedMonth = date
            selectedDate = nil
        }
    }

    private func showCurrentMonth() {
        displayedMonth = Date()
        selectedDate = nil
        refreshID += 1
    }
}

struct MonthCalendarView: View {
    let month: CalendarMonth
    let eventDays: Set<Date>
    let onSelectDate: (Date) -> Void
    let onChangeMonth: (Int) -> Void
    let onShowCurrentMonth: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text(month.interval.start.formatted(.dateTime.month(.abbreviated).year()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    monthButton(symbol: "chevron.left", label: "Previous month") {
                        onChangeMonth(-1)
                    }
                    Button("Today", action: onShowCurrentMonth)
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .help("Show current month")
                    monthButton(symbol: "chevron.right", label: "Next month") {
                        onChangeMonth(1)
                    }
                }
                .frame(height: 20)

                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(month.weekdaySymbols[index])
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.55))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 12)
                .accessibilityHidden(true)

                // Share the available panel height across four, five, or six weeks.
                let rowHeight = max(0, geometry.size.height - 36) / CGFloat(month.weekCount)
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(month.days.indices, id: \.self) { index in
                        if let date = month.days[index] {
                            dayButton(date: date, height: rowHeight)
                        } else {
                            Color.clear
                                .frame(height: rowHeight)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private func monthButton(
        symbol: String, label: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func dayButton(date: Date, height: CGFloat) -> some View {
        let isToday = month.calendar.isDateInToday(date)
        let hasEvents = eventDays.contains(date)
        let fontSize = min(12, max(9, height * 0.55))

        return Button {
            onSelectDate(date)
        } label: {
            VStack(spacing: 0) {
                Text("\(month.calendar.component(.day, from: date))")
                    .font(.system(size: fontSize, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? .white : Color(white: 0.8))
                    .frame(height: fontSize * 1.2)
                Circle()
                    .fill(hasEvents ? Color.effectiveAccent : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if isToday {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.effectiveAccentBackground)
                        .frame(width: 22)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(date.formatted(date: .complete, time: .omitted))
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasEvents ? Text("Has events") : Text("No events"))
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles


    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        guard autoScrollToNextEvent else { return }
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = events.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = events.first(where: { $0.isAllDay })
        let lastEvent = events.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(events) { event in
                    Button(action: {
                        if let url = event.calendarAppURL() {
                            openURL(url)
                        }
                    }) {
                        eventRow(event)
                    }
                    .id(event.id)
                    .padding(.leading, -5)
                    .buttonStyle(PlainButtonStyle())
                    .listRowSeparator(.automatic)
                    .listRowSeparatorTint(.gray.opacity(0.2))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: events) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
    }

    private func eventRow(_ event: EventModel) -> some View {
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            return AnyView(
                HStack(spacing: 8) {
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: Color(event.calendar.color)
                    )
                    .opacity(1.0)  // Ensure the toggle is always fully opaque
                    HStack {
                        Text(event.title)
                            .font(.callout)
                            .foregroundColor(.white)
                            .lineLimit(showFullEventTitles ? nil : 1)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if event.isAllDay {
                                Text("All-day")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            } else {
                                Text(event.start, style: .time)
                                    .foregroundColor(.white)
                                    .font(.caption)
                            }
                        }
                    }
                    .opacity(
                        isCompleted
                            ? 0.4
                            : event.start < Date.now && Calendar.current.isDateInToday(event.start)
                                ? 0.6 : 1.0
                    )
                }
                .padding(.vertical, 4)
            )
        } else {
            return AnyView(
                HStack(alignment: .top, spacing: 4) {
                    Rectangle()
                        .fill(Color(event.calendar.color))
                        .frame(width: 3)
                        .cornerRadius(1.5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .lineLimit(showFullEventTitles ? nil : 2)

                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundColor(Color(white: 0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if event.isAllDay {
                            Text("All-day")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(1)
                        } else {
                            Text(event.start, style: .time)
                                .foregroundColor(.white)
                            Text(event.end, style: .time)
                                .foregroundColor(Color(white: 0.65))
                        }
                    }
                    .font(.caption)
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .opacity(
                    event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                        ? 0.6 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
