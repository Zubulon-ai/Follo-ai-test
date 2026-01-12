//
//  CalendarView.swift
//  Follo AI
//
//  Created by GitHub Copilot on 2025/8/29.
//

import SwiftUI
import EventKit
import UIKit

// MARK: - EventKit Provider
@MainActor
final class CalendarEventProvider: ObservableObject {
    private let store = GlobalEventStore.shared.store
    @Published var authorization: EKAuthorizationStatus = .notDetermined
    @Published var eventsByDay: [DateComponents: [EKEvent]] = [:]
    @Published var selectedDate: DateComponents? = nil
    @Published var selectedDayEvents: [EKEvent] = []
    // Visible month for header display
    @Published var visibleMonth: DateComponents? = nil
    // Signal that a user tapped a date in month view and expects to enter day view
    @Published var shouldNavigateToDay: Bool = false
    // Throttle for month data loading
    private var lastEnsureLoadAt: Date? = nil

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(onEventStoreChanged), name: .EKEventStoreChanged, object: store)
    }

    // Cache window
    private var cachedRange: DateInterval? = nil

    var hasReadAccess: Bool {
        if #available(iOS 17.0, *) {
            return authorization == .fullAccess
        } else {
            return authorization == .authorized
        }
    }

    // Select a specific date and ensure its events are loaded
    func select(date: Date) {
        let cal = Calendar.current
        ensureEventsLoaded(around: date)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        setSelected(comps)
    }

    // Change selected day by delta; fallback to today if not set
    func changeDay(by delta: Int) {
        let cal = Calendar.current
        let baseDate: Date
        if let comps = selectedDate, let date = cal.date(from: comps) {
            baseDate = date
        } else {
            baseDate = Date()
        }
        guard let newDate = cal.date(byAdding: .day, value: delta, to: baseDate) else { return }
        select(date: newDate)
    }

    func requestAccessIfNeeded() async {
        let granted = await GlobalEventStore.shared.requestAccessIfNeeded()
        await MainActor.run {
            self.authorization = granted ?
                (EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess ? .fullAccess : .authorized) :
                .denied
        }
    }

    func ensureEventsLoaded(around date: Date = Date(), monthsBefore: Int = 1, monthsAfter: Int = 3) {
        // Build range only if not cached or date falls out of range
        let cal = Calendar.current
        let startMonth = cal.dateInterval(of: .month, for: date)!.start
        let start = cal.date(byAdding: .month, value: -monthsBefore, to: startMonth) ?? date
        let endMonth = cal.date(byAdding: .month, value: monthsAfter, to: startMonth) ?? date
        let end = cal.date(byAdding: .day, value: 40, to: cal.dateInterval(of: .month, for: endMonth)!.end) ?? endMonth

        let newRange = DateInterval(start: start, end: end)
        if let cached = cachedRange, cached.contains(date) && cached.contains(start) && cached.contains(end) {
            return
        }

    loadEvents(in: newRange)
        cachedRange = newRange
    }

    // Throttled variant to avoid frequent reload during month swipe
    func ensureEventsLoadedThrottled(around date: Date = Date(), monthsBefore: Int = 1, monthsAfter: Int = 3) {
        let now = Date()
        if let last = lastEnsureLoadAt, now.timeIntervalSince(last) < 0.3 { return }
        lastEnsureLoadAt = now
        ensureEventsLoaded(around: date, monthsBefore: monthsBefore, monthsAfter: monthsAfter)
    }

    private func loadEvents(in interval: DateInterval) {
    guard hasReadAccess else { return }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate)
        let cal = Calendar.current

        var map: [DateComponents: [EKEvent]] = [:]
        for ev in events {
            // Multi-day events appear each day they span
            var day = cal.startOfDay(for: ev.startDate)
            let endDay = cal.startOfDay(for: ev.endDate)
            while day <= endDay {
                let comps = cal.dateComponents([.year, .month, .day], from: day)
                map[comps, default: []].append(ev)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        DispatchQueue.main.async {
            self.eventsByDay = map
            if let sel = self.selectedDate {
                self.selectedDayEvents = map[sel] ?? []
            }
        }
    }

    @objc private func onEventStoreChanged() {
        // 当系统日历发生变化时，刷新当前缓存范围
        guard let range = cachedRange, hasReadAccess else { return }
        loadEvents(in: range)
    }

    func setSelected(_ dateComponents: DateComponents?) {
        selectedDate = dateComponents
        if let comps = dateComponents {
            selectedDayEvents = eventsByDay[comps] ?? []
        } else {
            selectedDayEvents = []
        }
    }

    // MARK: - Create/Save/Delete Helpers
    func makeDraftEvent(on baseDate: Date) -> EKEvent {
        let cal = Calendar.current
        // Round to next half hour
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: baseDate)
        let minute = comps.minute ?? 0
        let add = minute <= 30 ? (30 - minute) : (60 - minute)
        let start = cal.date(byAdding: .minute, value: add, to: baseDate) ?? baseDate
        let end = cal.date(byAdding: .minute, value: 60, to: start) ?? start.addingTimeInterval(3600)

        let ev = EKEvent(eventStore: store)
        ev.calendar = store.defaultCalendarForNewEvents ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
        ev.startDate = start
        ev.endDate = end
        ev.title = ""
        return ev
    }

    func save(event: EKEvent) throws {
        guard hasReadAccess else { throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "无权限访问日历"]) }
        if event.calendar == nil {
            event.calendar = store.defaultCalendarForNewEvents ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
        }
        try store.save(event, span: EKSpan.thisEvent, commit: true)
        // Refresh days covering event span
        refreshDays(from: event.startDate, to: event.endDate)
    }

    func delete(event: EKEvent) throws {
        guard hasReadAccess else { throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "无权限访问日历"]) }
        try store.remove(event, span: EKSpan.thisEvent, commit: true)
        refreshDays(from: event.startDate, to: event.endDate)
    }

    func refreshDays(from start: Date, to end: Date) {
        // Reload only the affected days and merge into eventsByDay to avoid losing cached months
        guard hasReadAccess else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: start)
        let endDayInclusive = cal.startOfDay(for: end)
        // Query a range that fully covers the affected days
        let interval = DateInterval(start: dayStart, end: (cal.date(byAdding: .day, value: 1, to: endDayInclusive) ?? end))
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate)

        var updated: [DateComponents: [EKEvent]] = [:]
        var day = dayStart
        while day <= endDayInclusive {
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            updated[comps] = []
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        for ev in events {
            var d = cal.startOfDay(for: ev.startDate)
            let endD = cal.startOfDay(for: ev.endDate)
            while d <= endD {
                let comps = cal.dateComponents([.year, .month, .day], from: d)
                if updated.keys.contains(comps) {
                    updated[comps, default: []].append(ev)
                }
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            }
        }
        DispatchQueue.main.async {
            var merged = self.eventsByDay
            for (k, v) in updated { merged[k] = v }
            self.eventsByDay = merged
            if let sel = self.selectedDate { self.selectedDayEvents = merged[sel] ?? [] }
        }
    }

    // Choose a calendar to reflect a color/type; for now prefer default editable calendar
    func calendar(closestTo color: Color, current: EKCalendar?) -> EKCalendar? {
        // Keep current if editable
        if let cur = current, cur.allowsContentModifications { return cur }
        let editable = store.calendars(for: EKEntityType.event).filter { $0.allowsContentModifications }
        return store.defaultCalendarForNewEvents ?? editable.first ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
    }
}

// MARK: - UIKit Calendar wrapper
@available(iOS 16.0, *)
struct UICalendarRepresentable: UIViewRepresentable {
    @ObservedObject var provider: CalendarEventProvider

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.locale = Locale.current
        view.calendar = TimeZoneManager.shared.currentCalendar()
        view.delegate = context.coordinator
    view.wantsDateDecorations = true

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.selectionBehavior = selection

        // Preload events around today
        provider.ensureEventsLoaded(around: Date())

    return view
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        // Keep the delegate up to date
        uiView.delegate = context.coordinator
        let selection = uiView.selectionBehavior as? UICalendarSelectionSingleDate
        if let selected = provider.selectedDate {
            var canApply = true
            if let vis = provider.visibleMonth {
                canApply = (vis.year == selected.year && vis.month == selected.month)
            }
            if canApply, selection?.selectedDate != selected {
                selection?.setSelected(selected, animated: false)
            }
        } else {
            if selection?.selectedDate != nil {
                selection?.setSelected(nil, animated: false)
            }
        }
            // If no visible month tracked yet, initialize from either selected or today
            if provider.visibleMonth == nil {
                let cal = Calendar.current
                let base = selection?.selectedDate.flatMap { cal.date(from: $0) } ?? Date()
                let comps = cal.dateComponents([.year, .month], from: base)
                if provider.visibleMonth?.year != comps.year || provider.visibleMonth?.month != comps.month {
                    DispatchQueue.main.async { withAnimation(nil) { provider.visibleMonth = comps } }
                }
            }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(provider: provider)
    }

    @MainActor
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        let provider: CalendarEventProvider
        init(provider: CalendarEventProvider) { self.provider = provider }

        // Decorations for dates with events
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            // Update visible month for header (month/year only) as fallback
            let monthComps = DateComponents(year: dateComponents.year, month: dateComponents.month)
            if provider.visibleMonth?.year != monthComps.year || provider.visibleMonth?.month != monthComps.month {
                // Only update if the date belongs to the currently visible month to avoid flickering
                if calendarView.visibleDateComponents.month == dateComponents.month {
                    withAnimation(nil) { self.provider.visibleMonth = monthComps }
                }
            }
            guard let events = provider.eventsByDay[dateComponents], !events.isEmpty else { return nil }
            if events.count <= 2 {
                return .default(color: .systemBlue, size: .medium)
            } else {
                return .default(color: .systemBlue, size: .large)
            }
        }

        // iOS 17: track current visible page to keep header & selection logic in sync
        @available(iOS 17.0, *)
        func calendarViewDidChangeVisibleDateComponents(_ calendarView: UICalendarView) {
            let comps = calendarView.visibleDateComponents
            withAnimation(nil) { self.provider.visibleMonth = DateComponents(year: comps.year, month: comps.month) }
        }

        // Selection handling
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            if let comps = dateComponents, let date = Calendar.current.date(from: comps) {
                provider.select(date: date)
                // Mark that this selection came from a direct user tap
                provider.shouldNavigateToDay = true
            } else {
                provider.setSelected(nil)
            }
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            true
        }
    }
}

// MARK: - Calendar Screen
struct CalendarScreen: View {
    @StateObject private var provider = CalendarEventProvider()
    @ObservedObject private var timeZoneManager = TimeZoneManager.shared
    @State private var navigateToDay: Bool = false
    @State private var editorItem: CalendarEditorItem? = nil
    
    // 控制是否显示按钮 - 默认true（用于日程标签页），false（用于其他页面跳转）
    let showActionButtons: Bool
    
    init(showActionButtons: Bool = true) {
        self.showActionButtons = showActionButtons
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                content
            } else {
                Text("需要 iOS 16 及以上版本才能使用日历视图")
                    .foregroundColor(.secondary)
            }
        }
    .navigationTitle(monthTitle())
    .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $navigateToDay) {
            DayViewScreen(provider: provider, date: currentSelectedDate())
        }
        .task {
            await provider.requestAccessIfNeeded()
            if provider.hasReadAccess {
                provider.ensureEventsLoaded()
            }
            // Ensure there is an initial selection (today)
            if provider.selectedDate == nil {
                provider.select(date: Date())
            }
            // 初始化时区管理器
            timeZoneManager.requestLocationPermission()
        }
        .onChange(of: provider.shouldNavigateToDay) { oldValue, newValue in
            guard newValue else { return }
            navigateToDay = true
            provider.shouldNavigateToDay = false
        }
        .onChange(of: provider.visibleMonth) { oldValue, newValue in
            // 只在整月变化时触发加载，避免 decoration 阶段频繁加载造成抖动
            if let comps = newValue, let date = Calendar.current.date(from: comps) {
                provider.ensureEventsLoadedThrottled(around: date)
            }
        }
        .sheet(item: $editorItem) { item in
            if #available(iOS 16.0, *) {
                EventEditView(provider: provider, event: item.event) { _ in }
            } else {
                Text("需要 iOS 16 及以上版本")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if provider.hasReadAccess {
            VStack(spacing: 0) {
                // 日历组件 - 进一步减少高度，为下方日程列表腾出更多空间
                UICalendarRepresentable(provider: provider)
                    .frame(height: 320) // 进一步减少高度到320点
                    .clipped()
                    .padding(.horizontal, 2)
                
                Divider()
                
                // 时区信息和操作按钮 - 压缩高度
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("时区：")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(timeZoneManager.getTimeZoneInfo())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    // 只在日程标签页显示操作按钮
                    if showActionButtons {
                        HStack(spacing: 8) {
                            // 日视图按钮
                            NavigationLink(destination: DayViewScreen(provider: provider, date: currentSelectedDate())) {
                                Image(systemName: "rectangle.grid.1x2")
                                    .font(.system(size: 14))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .accessibilityLabel("打开日视图")

                            // 添加日程按钮
                            Button {
                                let date = currentSelectedDate()
                                editorItem = CalendarEditorItem(event: provider.makeDraftEvent(on: date))
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .accessibilityLabel("添加日程")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4) // 减少垂直内边距
                
                // 事件列表 - 使用可滚动区域填充剩余空间
                ScrollView {
                    DayEventListFixed(events: provider.selectedDayEvents, selectedDate: provider.selectedDate) { ev in
                        editorItem = CalendarEditorItem(event: ev)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100) // 为底部TabView导航栏预留空间
                }
            }
    } else if provider.authorization == .denied || provider.authorization == .restricted {
            PermissionView()
    } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("请求日历权限中…")
                    .foregroundColor(.secondary)
            }
    }
    }

    private func monthTitle() -> String {
        let cal = timeZoneManager.currentCalendar()
        let comps = provider.visibleMonth ?? provider.selectedDate
        let date = comps.flatMap { cal.date(from: $0) } ?? Date()
        let f = timeZoneManager.dateFormatter(style: .none, timeStyle: .none)
        f.setLocalizedDateFormatFromTemplate("yyyy MMMM")
        return f.string(from: date)
    }

    private func currentSelectedDate() -> Date {
        let cal = timeZoneManager.currentCalendar()
        if let comps = provider.selectedDate, let date = cal.date(from: comps) {
            return date
        }
        return Date()
    }
}

// MARK: - Subviews
private struct CalendarEditorItem: Identifiable, Equatable {
    let id = UUID()
    let event: EKEvent
    static func == (lhs: CalendarEditorItem, rhs: CalendarEditorItem) -> Bool {
        lhs.event.calendarItemIdentifier == rhs.event.calendarItemIdentifier
    }
}
private struct DayEventList: View {
    let events: [EKEvent]
    let selectedDate: DateComponents?
    var onTap: ((EKEvent) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("共 \(events.count) 条")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if events.isEmpty {
                Text("无日程")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(events, id: \._uuid) { ev in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ev.title)
                                    .font(.body)
                                Text(timeRange(for: ev))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap?(ev) }
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }
        }
    }
    
    private var title: String {
        let cal = TimeZoneManager.shared.currentCalendar()
        if let comps = selectedDate, let date = cal.date(from: comps) {
            let f = TimeZoneManager.shared.dateFormatter(style: .medium, timeStyle: .none)
            return f.string(from: date)
        }
        return "请选择日期"
    }

    private func timeRange(for event: EKEvent) -> String {
        if event.isAllDay {
            return "全天"
        } else {
            let f = TimeZoneManager.shared.dateFormatter(style: .none, timeStyle: .short)
            let startTime = f.string(from: event.startDate)
            let endTime = f.string(from: event.endDate)
            return "\(startTime) - \(endTime) (\(TimeZoneManager.shared.timeZoneAbbreviation))"
        }
    }
}

// 优化版本的事件列表，去掉固定高度限制，适应动态布局
private struct DayEventListFixed: View {
    let events: [EKEvent]
    let selectedDate: DateComponents?
    var onTap: ((EKEvent) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("共 \(events.count) 条")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if events.isEmpty {
                Text("无日程")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(events, id: \._uuid) { ev in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ev.title)
                                .font(.body)
                            Text(timeRange(for: ev))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap?(ev) }
                        if ev != events.last {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var title: String {
        let cal = TimeZoneManager.shared.currentCalendar()
        if let comps = selectedDate, let date = cal.date(from: comps) {
            let f = TimeZoneManager.shared.dateFormatter(style: .medium, timeStyle: .none)
            return f.string(from: date)
        }
        return "请选择日期"
    }

    private func timeRange(for event: EKEvent) -> String {
        if event.isAllDay {
            return "全天"
        } else {
            let f = TimeZoneManager.shared.dateFormatter(style: .none, timeStyle: .short)
            let startTime = f.string(from: event.startDate)
            let endTime = f.string(from: event.endDate)
            return "\(startTime) - \(endTime) (\(TimeZoneManager.shared.timeZoneAbbreviation))"
        }
    }
}

extension EKEvent {
    // Stable identifier for List
    var _uuid: String { eventIdentifier }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("需要日历访问权限")
                .font(.headline)
            Text("请前往 设置 > 隐私 > 日历 授权本应用访问，以显示您的日程。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
