//
//  ScheduleAnalyzer.swift
//  Follo AI
//
//  日程负荷分析
//

import Foundation
import EventKit

class ScheduleAnalyzer {
    private let eventStore = EKEventStore()

    func requestCalendarPermission() async {
        do {
            if #available(iOS 17.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                print("    [ScheduleAnalyzer] 日历权限: \(granted ? "已授予" : "未授予")")
            } else {
                // iOS 16及以下
                let status = EKEventStore.authorizationStatus(for: .event)
                if status == .notDetermined {
                    let granted = try await eventStore.requestAccess(to: .event)
                    print("    [ScheduleAnalyzer] 日历权限: \(granted ? "已授予" : "未授予")")
                } else {
                    print("    [ScheduleAnalyzer] 日历权限状态: \(status == .authorized ? "已授予" : "未授予")")
                }
            }
        } catch {
            print("    [ScheduleAnalyzer] 请求日历权限失败: \(error)")
        }
    }
    
    private func checkCalendarAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        print("    [ScheduleAnalyzer] 当前日历权限状态: \(status.rawValue)")
        
        if #available(iOS 17.0, *) {
            let hasAccess = status == .fullAccess
            print("    [ScheduleAnalyzer] iOS 17+ 权限检查: \(hasAccess ? "fullAccess ✅" : "无完全访问权限 ❌")")
            return hasAccess
        } else {
            let hasAccess = status == .authorized
            print("    [ScheduleAnalyzer] iOS 16- 权限检查: \(hasAccess ? "authorized ✅" : "未授权 ❌")")
            return hasAccess
        }
    }

    func analyzeScheduleContext(currentEvent: Event) -> [String: Any] {
        let calendar = Calendar.current
        let now = Date()
        
        // 查询范围：从昨天到后天
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let endOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: now))!

        var context: [String: Any] = [
            "calendar.current_event": "none",
            "calendar.next_event": "none",
            "calendar.prev_event": "none",
            "calendar.gap_after_event": ">1440",
            "calendar.full_day_load": "unknown",
        ]

        // 获取昨天到后天的所有事件
        let events = getEventsForDay(start: startOfYesterday, end: endOfDayAfterTomorrow)
        
        print("    [ScheduleAnalyzer] 分析日程: 昨天到后天共 \(events.count) 个事件")

        // 分析当前正在进行的事件
        if let current = getCurrentEvent(at: now, from: events) {
            let title = current.title
            let startTime = current.startDate?.formatted(date: .omitted, time: .shortened) ?? "unknown"
            let endTime = current.endDate?.formatted(date: .omitted, time: .shortened) ?? "unknown"
            context["calendar.current_event"] = "\(title) (\(startTime) - \(endTime))"
            print("    [ScheduleAnalyzer] 当前事件: \(title)")
        } else {
            context["calendar.current_event"] = "none"
            print("    [ScheduleAnalyzer] 当前事件: 无")
        }

        // 分析下一个和上一个事件
        if let nextEvent = getNextEvent(after: now, from: events) {
            let nextTitle = nextEvent.title
            let datePrefix = getRelativeDateString(for: nextEvent.startDate, relativeTo: now)
            let nextTime = nextEvent.startDate?.formatted(date: .omitted, time: .shortened) ?? "unknown"
            context["calendar.next_event"] = "\(nextTitle) \(datePrefix) at \(nextTime)"
            print("    [ScheduleAnalyzer] 下一个事件: \(nextTitle) \(datePrefix)")
        } else {
            context["calendar.next_event"] = "none"
            print("    [ScheduleAnalyzer] 下一个事件: 无")
        }

        if let prevEvent = getPreviousEvent(before: now, from: events) {
            let prevTitle = prevEvent.title
            let datePrefix = getRelativeDateString(for: prevEvent.endDate, relativeTo: now)
            let prevTime = prevEvent.endDate?.formatted(date: .omitted, time: .shortened) ?? "unknown"
            context["calendar.prev_event"] = "\(prevTitle) \(datePrefix) ended at \(prevTime)"
            print("    [ScheduleAnalyzer] 上一个事件: \(prevTitle) \(datePrefix)")
        } else {
            context["calendar.prev_event"] = "none"
            print("    [ScheduleAnalyzer] 上一个事件: 无")
        }

        // 计算日程间隙
        if let currentEventEnd = currentEvent.endDate,
           let nextEvent = getNextEvent(after: currentEventEnd, from: events) {
            let gapMinutes = Int(nextEvent.startDate?.timeIntervalSince(currentEventEnd) ?? 0) / 60
            context["calendar.gap_after_event"] = gapMinutes > 1440 ? ">1440" : "\(gapMinutes)"
            print("    [ScheduleAnalyzer] 事件后间隙: \(gapMinutes)分钟")
        } else {
            context["calendar.gap_after_event"] = ">1440"
            print("    [ScheduleAnalyzer] 事件后间隙: >1440分钟")
        }

        // 分析当日负荷（只分析今天的事件）
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let todayEvents = events.filter { event in
            guard let eventStart = event.startDate else { return false }
            return eventStart >= todayStart && eventStart < todayEnd
        }
        let load = analyzeDailyLoad(events: todayEvents, date: now)
        context["calendar.full_day_load"] = load
        print("    [ScheduleAnalyzer] 今日负荷: \(load) (基于\(todayEvents.count)个今日事件)")

        return context
    }

    private func getEventsForDay(start: Date, end: Date) -> [Event] {
        guard checkCalendarAccess() else {
            print("    [ScheduleAnalyzer] 没有日历权限，无法获取事件")
            return []
        }
        
        // 调试：打印可用的日历
        let calendars = eventStore.calendars(for: .event)
        print("    [ScheduleAnalyzer] 找到 \(calendars.count) 个日历源:")
        for cal in calendars {
            print("      - \(cal.title) (类型: \(cal.type.rawValue), 可编辑: \(cal.allowsContentModifications))")
        }
        
        // 调试：打印查询时间范围
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("    [ScheduleAnalyzer] 查询时间范围: \(formatter.string(from: start)) 至 \(formatter.string(from: end))")
        
        // 创建谓词查询（nil 表示查询所有日历）
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)
        
        print("    [ScheduleAnalyzer] 从 EKEventStore 获取到 \(ekEvents.count) 个原始事件")
        
        // 调试：打印前3个事件
        if ekEvents.count > 0 {
            print("    [ScheduleAnalyzer] 事件列表（前3个）:")
            for (index, event) in ekEvents.prefix(3).enumerated() {
                let startStr = formatter.string(from: event.startDate)
                print("      \(index + 1). \(event.title ?? "无标题") - \(startStr)")
            }
        }
        
        // 转换为自定义Event结构
        return ekEvents.map { ekEvent in
            Event(
                title: ekEvent.title ?? "无标题",
                startDate: ekEvent.startDate,
                endDate: ekEvent.endDate,
                location: ekEvent.location,
                isAllDay: ekEvent.isAllDay
            )
        }
    }

    private func getNextEvent(after date: Date, from events: [Event]) -> Event? {
        return events.first { $0.startDate ?? Date.distantFuture > date }
    }

    private func getCurrentEvent(at date: Date, from events: [Event]) -> Event? {
        return events.first { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            return start <= date && end >= date
        }
    }

    private func getPreviousEvent(before date: Date, from events: [Event]) -> Event? {
        return events.last { $0.endDate ?? Date.distantPast < date }
    }
    
    /// 获取相对日期字符串（今天/明天/后天/昨天等）
    private func getRelativeDateString(for eventDate: Date?, relativeTo referenceDate: Date) -> String {
        guard let eventDate = eventDate else { return "" }
        
        let calendar = Calendar.current
        let eventDay = calendar.startOfDay(for: eventDate)
        let referenceDay = calendar.startOfDay(for: referenceDate)
        
        let daysDifference = calendar.dateComponents([.day], from: referenceDay, to: eventDay).day ?? 0
        
        switch daysDifference {
        case 0:
            return "今天"
        case 1:
            return "明天"
        case 2:
            return "后天"
        case -1:
            return "昨天"
        case -2:
            return "前天"
        default:
            // 其他日期显示具体日期
            let formatter = DateFormatter()
            formatter.dateFormat = "MM月dd日"
            return formatter.string(from: eventDate)
        }
    }

    private func analyzeDailyLoad(events: [Event], date: Date) -> String {
        // 改进的负荷算法：综合考虑事件数量、总时长和事件密度
        let totalEvents = events.count
        
        // 如果没有事件，负荷为低
        if totalEvents == 0 {
            return "low"
        }
        
        // 计算总时长（小时）
        let totalDuration = events.compactMap { event in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return end.timeIntervalSince(start)
        }.reduce(0.0, +)
        let totalHours = totalDuration / 3600
        
        // 计算平均事件时长
        let avgDuration = totalHours / Double(totalEvents)
        
        // 计算事件密度（事件数量/工作时间比例）
        // 工作时间按12小时计算（8:00-20:00）
        let workingHours = 12.0
        let eventDensity = totalHours / workingHours
        
        // 综合评分系统
        var score = 0
        
        // 1. 基于总时长评分 (0-4分)
        switch totalHours {
        case 0..<2:     score += 0
        case 2..<4:     score += 1
        case 4..<6:     score += 2
        case 6..<8:     score += 3
        default:        score += 4
        }
        
        // 2. 基于事件数量评分 (0-3分)
        switch totalEvents {
        case 0...2:     score += 0
        case 3...4:     score += 1
        case 5...6:     score += 2
        default:        score += 3
        }
        
        // 3. 基于事件密度评分 (0-3分)
        // 密度 > 0.7 表示一天中超过70%的时间都有安排
        switch eventDensity {
        case 0..<0.3:   score += 0  // 小于30%时间有安排
        case 0.3..<0.5: score += 1  // 30-50%时间有安排
        case 0.5..<0.7: score += 2  // 50-70%时间有安排
        default:        score += 3  // 超过70%时间有安排
        }
        
        // 根据总分判断负荷等级 (总分0-10)
        switch score {
        case 0...2:     return "low"        // 0-2分：低负荷
        case 3...5:     return "medium"     // 3-5分：中等负荷
        case 6...8:     return "high"       // 6-8分：高负荷
        default:        return "very_high"  // 9-10分：极高负荷
        }
    }
}
