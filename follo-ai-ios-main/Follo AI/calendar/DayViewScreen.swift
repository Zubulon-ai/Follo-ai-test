//
//  DayViewScreen.swift
//  Follo AI
//
//  Created by GitHub Copilot on 2025/8/29.
//

import SwiftUI
import EventKit

@available(iOS 16.0, *)
struct DayViewScreen: View {
    @ObservedObject var provider: CalendarEventProvider
    @State var date: Date
    var highlightEventId: String? = nil
    @State private var editorItem: EditorItem? = nil
    @State private var dayTransitionEdge: Edge = .trailing

    private let hourHeight: CGFloat = 60
    private let minEventHeight: CGFloat = 28
    private let eventCorner: CGFloat = 8
    private let eventPadding: CGFloat = 6
    private let columnSpacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 8) {
            // 日期header和操作按钮
            HStack {
                WeekHeader(selectedDate: $date, provider: provider) { newDate in
                    // 根据新旧日期判断方向
                    dayTransitionEdge = (newDate > date) ? .trailing : .leading
                    provider.select(date: newDate)
                    withAnimation(.easeInOut(duration: 0.28)) { date = newDate }
                }
                
                Spacer()
                
                // 添加日程按钮
                Button {
                    let draft = provider.makeDraftEvent(on: date)
                    editorItem = EditorItem(event: draft)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("添加日程")
            }
            .padding(.horizontal)
            dayContent
                .id(date)
                .transition(.asymmetric(
                    insertion: .move(edge: dayTransitionEdge),
                    removal: .move(edge: dayTransitionEdge == .leading ? .trailing : .leading)
                ))
                .animation(.easeInOut(duration: 0.28), value: date)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            let horizontal = abs(value.translation.width) > abs(value.translation.height)
                            guard horizontal else { return }
                            if value.translation.width < -40 { // 左滑 → 下一天
                                dayTransitionEdge = .trailing
                                changeDay(1)
                            } else if value.translation.width > 40 { // 右滑 → 前一天
                                dayTransitionEdge = .leading
                                changeDay(-1)
                            }
                        }
                )
        }
        .padding(.horizontal)
        .navigationTitle(dayTitle(date))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await provider.requestAccessIfNeeded()
            provider.ensureEventsLoaded(around: date)
            provider.select(date: date)
        }
        .sheet(item: $editorItem, onDismiss: { refreshDay() }) { item in
            EventEditView(provider: provider, event: item.event) { action in
                switch action {
                case .saved, .deleted:
                    refreshDay()
                case .cancelled:
                    break
                }
                editorItem = nil
            }
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: date)
    }

    private func refreshDay() {
        provider.ensureEventsLoaded(around: date)
        provider.select(date: date)
    }

    private func changeDay(_ delta: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: delta, to: date) {
            provider.select(date: newDate)
            withAnimation(.easeInOut(duration: 0.28)) { date = newDate }
        }
    }

    private func dayEvents() -> (allDay: [EKEvent], timed: [EKEvent]) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let events = provider.eventsByDay[comps] ?? []
        let allDay = events.filter { $0.isAllDay }
        let timed = events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        return (allDay, timed)
    }
}

// 将日视图主体单独抽出以便做过渡动画
@available(iOS 16.0, *)
private extension DayViewScreen {
    @ViewBuilder
    var dayContent: some View {
        AllDaySection(events: dayEvents().allDay) { ev in
            editorItem = EditorItem(event: ev)
        }
        Divider()
        Timeline(baseDate: date,
                 events: dayEvents().timed,
                 highlightEventId: highlightEventId,
                 hourHeight: hourHeight,
                 minEventHeight: minEventHeight,
                 eventCorner: eventCorner,
                 eventPadding: eventPadding,
                 columnSpacing: columnSpacing) { ev in
            editorItem = EditorItem(event: ev)
        }
    }
}

// MARK: - Week Header
@available(iOS 16.0, *)
private struct WeekHeader: View {
    @Binding var selectedDate: Date
    let provider: CalendarEventProvider
    var onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { changeDay(-1) }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            ForEach(daysOfWeek(), id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                VStack(spacing: 2) {
                    Text(weekdaySymbol(for: day))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .frame(width: 28, height: 28)
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.footnote.weight(isToday ? .bold : .regular))
                            .foregroundColor(isSelected ? .white : .primary)
                    }
                    if hasEvents(on: day) {
                        Circle().fill(Color.blue).frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(day)
                    selectedDate = day
                }
            }
            Spacer(minLength: 0)
            Button(action: { changeDay(1) }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
        }
        // Horizontal swipe: left -> next day, right -> previous day
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    let horizontal = abs(value.translation.width) > abs(value.translation.height) && abs(value.translation.width) > 16
                    guard horizontal else { return }
                    if value.translation.width < -20 {
                        changeDay(1)
                    } else if value.translation.width > 20 {
                        changeDay(-1)
                    }
                }
        )
    }

    private func daysOfWeek() -> [Date] {
        let cal = Calendar.current
        let interval = cal.dateInterval(of: .weekOfYear, for: selectedDate)!
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func weekdaySymbol(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    private func hasEvents(on date: Date) -> Bool {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (provider.eventsByDay[comps] ?? []).isEmpty == false
    }

    private func changeDay(_ delta: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) {
            onSelect(newDate)
            selectedDate = newDate
        }
    }
}

// MARK: - All Day Section
@available(iOS 16.0, *)
private struct AllDaySection: View {
    let events: [EKEvent]
    var onTap: (EKEvent) -> Void
    var body: some View {
        if events.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("全天")
                    .font(.caption)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events, id: \._uuid) { ev in
                        Text(ev.title)
                            .font(.footnote)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                                .background(ev.harvestDisplayColor.opacity(0.12))
                                .foregroundColor(ev.harvestDisplayColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .onTapGesture { onTap(ev) }
                    }
                }
            }
        }
    }
}

// MARK: - Timeline with placed events
@available(iOS 16.0, *)
private struct Timeline: View {
    let baseDate: Date
    let events: [EKEvent]
    let highlightEventId: String?
    let hourHeight: CGFloat
    let minEventHeight: CGFloat
    let eventCorner: CGFloat
    let eventPadding: CGFloat
    let columnSpacing: CGFloat
    var onTap: (EKEvent) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Hour grid
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            HStack(spacing: 8) {
                                VStack(spacing: 0) {
                                    Text(String(format: "%02d:00", h))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .id("hour-\(h)")
                                    Spacer(minLength: 0)
                                }
                                .frame(width: 40, alignment: .topTrailing)
                                // Ensure the hour line is at the TOP of each hour slot
                                VStack(spacing: 0) {
                                    // draw the line at the very top
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(height: 0.5)
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: hourHeight)
                        }
                    }

                    // Events overlay
                    GeometryReader { geo in
                        let availableWidth = geo.size.width - 40 - 8 // subtract hour label and spacing
                        let placed = place(events: events)
                        ForEach(placed.indices, id: \.self) { idx in
                            let item = placed[idx]
                            let y = yPosition(for: item.event.startDate)
                            let height = max(minEventHeight, yPosition(for: item.event.endDate) - y)
                            let width = (availableWidth - CGFloat(item.totalColumns - 1) * columnSpacing) / CGFloat(max(item.totalColumns, 1))
                            let x = 40 + 8 + CGFloat(item.columnIndex) * (width + columnSpacing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.event.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(timeRange(for: item.event))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .frame(width: width, height: height, alignment: .topLeading)
                            .background(item.event.harvestDisplayColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: eventCorner)
                                    .strokeBorder(borderColor(for: item.event), lineWidth: borderWidth(for: item.event))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: eventCorner, style: .continuous))
                            .offset(x: x, y: y)
                .onTapGesture { onTap(item.event) }
                        }
                    }
                }
                .frame(height: hourHeight * 24)
            }
            .onAppear {
                // Scroll to highlighted event's hour if provided; else near current time
                if let hid = highlightEventId,
                   let ev = events.first(where: { $0.eventIdentifier == hid }) {
                    let h = Calendar.current.component(.hour, from: ev.startDate)
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo("hour-\(max(min(h, 23), 0))", anchor: .center)
                    }
                } else {
                    let hour = Calendar.current.component(.hour, from: Date())
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("hour-\(max(min(hour, 23), 0))", anchor: .center)
                    }
                }
            }
        }
    }

    private func isHighlighted(_ ev: EKEvent) -> Bool {
        guard let hid = highlightEventId else { return false }
        return ev.eventIdentifier == hid
    }

    private func borderColor(for ev: EKEvent) -> Color {
        isHighlighted(ev) ? .accentColor : ev.harvestDisplayColor.opacity(0.35)
    }

    private func borderWidth(for ev: EKEvent) -> CGFloat {
        isHighlighted(ev) ? 2.5 : 1
    }

    private func yPosition(for date: Date) -> CGFloat {
        // Compute offset relative to the displayed day's start, and clamp within [0, 24h]
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: baseDate)
    let seconds = max(0, min(CGFloat(date.timeIntervalSince(dayStart)), 24 * 3600))
    let raw = seconds / 3600.0 * hourHeight
    // Snap to pixel grid to avoid anti-aliasing visual drift
    let scale = UIScreen.main.scale
    return round(raw * scale) / scale
    }

    private func timeRange(for event: EKEvent) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: event.startDate)) - \(f.string(from: event.endDate))"
    }

    // Place events into columns with basic overlap handling
    private func place(events: [EKEvent]) -> [PlacedEvent] {
        var placed: [PlacedEvent] = []
        var columnsEnd: [Date] = [] // end time per column
        var activeIndices: [Int] = [] // indices in 'placed' currently overlapping

        let sorted = events.sorted { a, b in
            if a.startDate == b.startDate { return a.endDate < b.endDate }
            return a.startDate < b.startDate
        }

        func cleanup(at currentStart: Date) {
            // free columns and remove inactive events
            for (i, end) in columnsEnd.enumerated() {
                if end <= currentStart {
                    columnsEnd[i] = .distantPast
                }
            }
            activeIndices.removeAll { idx in placed[idx].event.endDate <= currentStart }
        }

        for ev in sorted {
            cleanup(at: ev.startDate)
            // find first free column
            var col = 0
            while col < columnsEnd.count, columnsEnd[col] > ev.startDate { col += 1 }
            if col == columnsEnd.count {
                columnsEnd.append(ev.endDate)
            } else {
                columnsEnd[col] = ev.endDate
            }

            let totalCols = columnsEnd.filter { $0 > ev.startDate }.count

            // ensure active events know the new max columns if expanded
            for idx in activeIndices { placed[idx].totalColumns = max(placed[idx].totalColumns, totalCols) }

            let item = PlacedEvent(event: ev, columnIndex: col, totalColumns: max(totalCols, 1))
            placed.append(item)
            activeIndices.append(placed.count - 1)
        }
        return placed
    }
}

private struct PlacedEvent {
    let event: EKEvent
    let columnIndex: Int
    var totalColumns: Int
}

// MARK: - Editor Item for sheet presentation
@available(iOS 16.0, *)
private struct EditorItem: Identifiable, Equatable {
    let id = UUID()
    let event: EKEvent
    static func == (lhs: EditorItem, rhs: EditorItem) -> Bool { lhs.event.calendarItemIdentifier == rhs.event.calendarItemIdentifier }
}
