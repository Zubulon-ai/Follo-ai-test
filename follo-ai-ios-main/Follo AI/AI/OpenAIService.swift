//
//  OpenAIService.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/8/13.
//

import Foundation
import EventKit
import CoreLocation

// 用户信息结构体
public struct UserInfo: Codable {
    let age: String
    let profession: String
    let gender: String
}

class OpenAIService: ObservableObject {
    // 使用后端 API 服务替代直接调用 DashScope
    private let backendAPI = BackendAPIService()

    @Published var isLoading = false
    @Published var lastResponse = ""
    @Published var errorMessage = ""
    @Published var suggestionText: String = ""
    // 商业化推荐结果（按置信度排序后由 UI 展示）
    @Published var recommendations: [CommercialRecommendationItem] = []
    private let eventStore = GlobalEventStore.shared.store
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
    f.timeZone = TimeZone.current
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()

    // 统一：将一批 EKEvent 格式化为“按天 -> 中文自然语言”的字符串
    // 示例（不含 id，含 日程类型 字段；按天聚合）：
    // 9月29日：
    //  - 时间 10:00-11:35，标题：体育五，地点：体育馆篮球场，备注：xxxx，日程类型：大三上课表
    // 9月30日：
    //  - 时间 09:00-10:00，标题：项目同步，地点：会议室A，备注：，日程类型：工作
    private func buildNaturalLanguageSchedule(from events: [EKEvent], dateRange: ClosedRange<Date>?, defaultScheduleType: String?) -> String {
        let cal = Calendar.current
        let fmtDay = DateFormatter()
        fmtDay.locale = Locale(identifier: "zh_CN")
        fmtDay.timeZone = TimeZone.current
        fmtDay.dateFormat = "M月d日"
        let fmtTime = DateFormatter()
        fmtTime.locale = Locale(identifier: "zh_CN")
        fmtTime.timeZone = TimeZone.current
        fmtTime.dateFormat = "HH:mm"

        // 过滤日期范围（如提供）且有起止时间
        let filtered: [EKEvent] = events.compactMap { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return nil }
            if let r = dateRange {
                if e < r.lowerBound || s > r.upperBound { return nil }
            }
            return ev
        }

        if filtered.isEmpty { return "无日程" }

        // 按天分组
        var byDay: [Date: [EKEvent]] = [:]
        for ev in filtered {
            let day = cal.startOfDay(for: ev.startDate ?? Date())
            byDay[day, default: []].append(ev)
        }

        // 每天按开始时间排序
        for (k, list) in byDay { byDay[k] = list.sorted { (a, b) in
            let asd = a.startDate ?? Date.distantPast
            let bsd = b.startDate ?? Date.distantPast
            return asd < bsd
        }}

        // 将每一天转中文段落
        let sortedDays = byDay.keys.sorted()
        var lines: [String] = []
        for day in sortedDays {
            lines.append("\(fmtDay.string(from: day))：")
            for ev in byDay[day] ?? [] {
                guard let s = ev.startDate, let e = ev.endDate else { continue }
                let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let loc = (ev.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = (ev.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let timeStr: String = {
                    if ev.isAllDay {
                        return "全天"
                    } else {
                        return "\(fmtTime.string(from: s))-\(fmtTime.string(from: e))"
                    }
                }()
                let scheduleType = defaultScheduleType ?? ev.calendar.title
                var seg = "  - 时间 \(timeStr)，标题：\(title.isEmpty ? "(无标题)" : title)"
                if !loc.isEmpty { seg += "，地点：\(loc)" }
                if !notes.isEmpty { seg += "，备注：\(notes)" }
                seg += "，日程类型：\(scheduleType)"
                lines.append(seg)
            }
        }
        return lines.joined(separator: "\n")
    }

    // 结构化 JSON：按天分组（中文键名、无 id，包含自然语言便于显示与解析）
    // 顶层：{"日程":[{"日期":"9月29日","事件":[{"时间":"10:00-11:35","标题":"...","地点":"...","备注":"...","日程类型":"...","开始":"ISO","结束":"ISO","是否全天":false,"时区":"Asia/Shanghai"}]}]}
    private func buildStructuredScheduleJSON(from events: [EKEvent], dateRange: ClosedRange<Date>?, defaultScheduleType: String?) throws -> String {
        let cal = Calendar.current
        let fmtDay = DateFormatter()
        fmtDay.locale = Locale(identifier: "zh_CN")
        fmtDay.timeZone = TimeZone.current
        fmtDay.dateFormat = "M月d日"
        let fmtTime = DateFormatter()
        fmtTime.locale = Locale(identifier: "zh_CN")
        fmtTime.timeZone = TimeZone.current
        fmtTime.dateFormat = "HH:mm"

        let filtered: [EKEvent] = events.compactMap { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return nil }
            if let r = dateRange { if e < r.lowerBound || s > r.upperBound { return nil } }
            return ev
        }

        if filtered.isEmpty {
            return try JSONSerialization.string(withJSONObject: ["日程": []])
        }

        var byDay: [Date: [EKEvent]] = [:]
        for ev in filtered {
            let day = cal.startOfDay(for: ev.startDate ?? Date())
            byDay[day, default: []].append(ev)
        }
        for (k, list) in byDay { byDay[k] = list.sorted { (a, b) in (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast) } }

        let sortedDays = byDay.keys.sorted()
        var dayItems: [[String: Any]] = []
        for day in sortedDays {
            var eventsArr: [[String: Any]] = []
            for ev in byDay[day] ?? [] {
                guard let s = ev.startDate, let e = ev.endDate else { continue }
                let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let loc = (ev.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = (ev.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let timeDisplay = ev.isAllDay ? "全天" : "\(fmtTime.string(from: s))-\(fmtTime.string(from: e))"
                var obj: [String: Any] = [
                    "时间": timeDisplay,
                    "标题": title.isEmpty ? "(无标题)" : title,
                    "日程类型": (defaultScheduleType ?? ev.calendar.title),
                    "开始": iso8601.string(from: s),
                    "结束": iso8601.string(from: e),
                    "是否全天": ev.isAllDay,
                    "时区": TimeZone.current.identifier
                ]
                if !loc.isEmpty { obj["地点"] = loc }
                if !notes.isEmpty { obj["备注"] = notes }
                eventsArr.append(obj)
            }
            let dayObj: [String: Any] = [
                "日期": fmtDay.string(from: day),
                "事件": eventsArr
            ]
            dayItems.append(dayObj)
        }

        return try JSONSerialization.string(withJSONObject: ["日程": dayItems])
    }

    // HAR专用：只包含今天；若今天没有事件，则包含最近一个已完成（Completed）和未来第一个（Next）
    // 返回结构：
    // {"日程": [{"日期":"M月d日","事件":[...]}], "最近已完成": {...可选}, "下一日程": {...可选}}
    private func buildHARSlimScheduleJSON(from events: [EKEvent]) throws -> String {
        let cal = Calendar.current
        let fmtDay = DateFormatter()
        fmtDay.locale = Locale(identifier: "zh_CN")
        fmtDay.timeZone = TimeZone.current
        fmtDay.dateFormat = "M月d日"
        let fmtTime = DateFormatter()
        fmtTime.locale = Locale(identifier: "zh_CN")
        fmtTime.timeZone = TimeZone.current
        fmtTime.dateFormat = "HH:mm"

        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86400)

        let valid = events.compactMap { ev -> EKEvent? in
            guard let _ = ev.startDate, let _ = ev.endDate else { return nil }
            return ev
        }.sorted { (a, b) in (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast) }

        let todayEvents = valid.filter { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return false }
            return !(e <= todayStart || s >= todayEnd)
        }

        func encodeEvent(_ ev: EKEvent) -> [String: Any] {
            let s = ev.startDate ?? Date()
            let e = ev.endDate ?? s
            let timeDisplay = ev.isAllDay ? "全天" : "\(fmtTime.string(from: s))-\(fmtTime.string(from: e))"
            var obj: [String: Any] = [
                "时间": timeDisplay,
                "标题": (ev.title ?? "").isEmpty ? "(无标题)" : (ev.title ?? ""),
                "日程类型": ev.calendar.title,
                "是否全天": ev.isAllDay
            ]
            if let loc = ev.location, !loc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { obj["地点"] = loc }
            if let notes = ev.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { obj["备注"] = notes }
            return obj
        }

        var payload: [String: Any] = [:]

        if !todayEvents.isEmpty {
            let arr = todayEvents.sorted { (a, b) in (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast) }.map { encodeEvent($0) }
            payload["日程"] = [["日期": fmtDay.string(from: todayStart), "事件": arr]]
        } else {
            payload["日程"] = []
            if let lastDone = valid.filter({ ($0.endDate ?? .distantPast) < now }).max(by: { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }) {
                payload["最近已完成"] = encodeEvent(lastDone)
            }
        }

        // 不管今日是否为空，都提供下一日程（若存在）
        if let next = valid.first(where: { ($0.startDate ?? .distantFuture) >= now }) {
            payload["下一日程"] = encodeEvent(next)
        }

        return try JSONSerialization.string(withJSONObject: payload)
    }
    
    func sendGreetingRequest() async {
        await MainActor.run {
            isLoading = true
            errorMessage = ""
        }

        do {
            // 使用后端 API 调用
            let response = try await backendAPI.sendGreeting()
            await MainActor.run {
                self.lastResponse = response
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "API调用失败: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    // 移除旧的行为预测接口

    // MARK: - 首页HAR一句话关怀
    func guessCurrentActivity(userInfo: UserInfo,
                              recentStatusData: [String],
                              appCalendarEvents: [EKEvent]?,
                              contextSignals: [SignalDescription]? = nil) async {
        await MainActor.run {
            isLoading = true
            errorMessage = ""
        }
        do {
            // HAR 专用日程：不再传递日程信息
            let calendarJSON = "{}"

            // 使用传入的 contextSignals 或重新收集
            let signals: [SignalDescription]
            if let contextSignals = contextSignals {
                signals = contextSignals
            } else {
                signals = await ContextCollector.shared.collectContext()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let sensorJSON = try encoder.encode(signals)
            let sensorJSONString = String(data: sensorJSON, encoding: .utf8) ?? "{}"

            // current time info
            let now = Date()
            let currentTimeInfo: String = {
                let dict: [String: Any] = [
                    "now": iso8601.string(from: now),
                    "timezone": TimeZone.current.identifier
                ]
                let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
                return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            }()

            // 使用后端 API
            let text = try await backendAPI.harAnalysis(
                userInfo: userInfo,
                calendarJSON: calendarJSON,
                sensorJSON: sensorJSONString,
                currentTimeInfo: currentTimeInfo
            )

            await MainActor.run {
                self.lastResponse = text
                self.suggestionText = self.parseSuggestionText(from: text) ?? ""
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "AI分析失败: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    // MARK: - 商业化推荐调用
    func fetchCommercialRecommendations(userInfo: UserInfo,
                                        recentStatusData: [String],
                                        appCalendarEvents: [EKEvent]?,
                                        contextSignals: [SignalDescription]? = nil) async {
        do {
            // calendar（推荐App改为 HAR 相同结构：今日/最近已完成/下一日程）
            let calendarJSON: String
            if let events = appCalendarEvents, !events.isEmpty {
                calendarJSON = try buildHARSlimScheduleJSON(from: events)
            } else {
                calendarJSON = try await buildHARSlimScheduleJSONFromEventKit()
            }

            // 使用传入的 contextSignals 或重新收集
            let signals: [SignalDescription]
            if let contextSignals = contextSignals {
                signals = contextSignals
            } else {
                signals = await ContextCollector.shared.collectContext()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let sensorJSON = try encoder.encode(signals)
            let sensorJSONString = String(data: sensorJSON, encoding: .utf8) ?? "{}"

            // current time info
            let now = Date()
            let currentTimeInfo: String = {
                let dict: [String: Any] = [
                    "now": iso8601.string(from: now),
                    "timezone": TimeZone.current.identifier
                ]
                let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
                return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            }()

            // 使用后端 API
            let text = try await backendAPI.fetchRecommendations(
                userInfo: userInfo,
                calendarJSON: calendarJSON,
                sensorJSON: sensorJSONString,
                timeInfo: currentTimeInfo
            )

            // 首次解析
            if let items = parseCommercialRecommendations(from: text), !items.isEmpty {
                let sorted = items.sorted { ($0.confidence_score ?? 0) > ($1.confidence_score ?? 0) }
                await MainActor.run { self.recommendations = sorted }
            } else {
                // 兜底：强制严格 JSON 模式重试一次
                // 注意：后端 API 会处理重试逻辑，这里暂时跳过
                print("⚠️ 推荐JSON解析失败，保留空结果。")
            }
        } catch {
            // 推荐失败不阻塞主流程，仅打印错误
            print("商业化推荐失败: \(error)")
        }
    }

    private struct GuessSuggestionPayload: Codable { let suggestion_text: String? }
    private func parseSuggestionText(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        if let data = jsonStr.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(GuessSuggestionPayload.self, from: data) {
            return parsed.suggestion_text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = jsonStr.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8),
           let parsed2 = try? JSONDecoder().decode(GuessSuggestionPayload.self, from: data2) {
            return parsed2.suggestion_text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // 解析商业化推荐 JSON
    private func parseCommercialRecommendations(from text: String) -> [CommercialRecommendationItem]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        let dec = JSONDecoder()
        if let data = jsonStr.data(using: .utf8) {
            if let resp = try? dec.decode(CommercialRecommendationResponse.self, from: data) {
                return resp.recommendations
            }
        }
        let cleaned = jsonStr.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8) {
            if let resp2 = try? dec.decode(CommercialRecommendationResponse.self, from: data2) {
                return resp2.recommendations
            }
        }
        return nil
    }

    // MARK: - Meeting Assistant (协作助手) 调用
    func callMeetingAssistant(
        promptText: String,
        recipientName: String,
        recipientPrefsJSON: String,
        recipientCalendarJSON: String,
        requesterName: String,
        requesterUserInfo: UserInfo?,
        requesterAppCalendarEvents: [EKEvent]?
    ) async throws -> String {
        // 使用后端 API
        let text = try await backendAPI.meetingAssistant(
            promptText: promptText,
            recipientName: recipientName,
            recipientPrefsJSON: recipientPrefsJSON,
            recipientCalendarJSON: recipientCalendarJSON,
            requesterName: requesterName,
            requesterUserInfo: requesterUserInfo,
            requesterCalendarEvents: requesterAppCalendarEvents
        )

        print("\n📥 === MeetingApp 回复文本 ===\n\(text)\n==========================\n")
        return text
    }

    // MARK: - Quick Create (快速创建) 调用
    func callQuickCreateApp(
        prompt: String,
        userInfo: UserInfo?,
        appCalendarEvents: [EKEvent]?,
        recentStatusData: [String]
    ) async throws -> String {
        // 使用新的ContextCollector收集21个信号
        let signals = await ContextCollector.shared.collectContext()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let sensorJSON = try encoder.encode(signals)
        let sensorJSONString = String(data: sensorJSON, encoding: .utf8) ?? "{}"

        // 使用后端 API
        let text = try await backendAPI.quickCreate(
            prompt: prompt,
            userInfo: userInfo,
            calendarEvents: appCalendarEvents,
            recentStatusData: recentStatusData
        )

        print("\n📥 === QuickCreate 回复文本 ===\n\(text)\n==========================\n")
        return text
    }


	// 便捷重载：自动构建三个模板变量，确保请求体包含 preference/Calendar/Sensor
    func callDashScopeApp(prompt: String,
                          userInfo: UserInfo?,
                          appCalendarEvents: [EKEvent]?,
                          recentStatusData: [String],
                          onAnalysis: (([AnalysisTask]) -> Void)? = nil,
                          onPartial: ((AnalysisTask, String) -> Void)? = nil,
                          onCandidates: ((String, [LocatedEventCandidate]) -> Void)? = nil) async throws -> String {
        // 直接使用后端 API
        let response = try await backendAPI.chat(
            prompt: prompt,
            userInfo: userInfo,
            calendarEvents: appCalendarEvents,
            recentStatusData: recentStatusData
        )

        return response
    }

    // 将用户基本信息编码为 JSON 字符串
    private func buildPreferenceJSON(userInfo: UserInfo) throws -> String {
        let dict: [String: String] = [
            "age": userInfo.age,
            "profession": userInfo.profession,
            "gender": userInfo.gender
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // 旧 JSON 导出函数保留签名，但内部改为输出结构化中文 JSON（向后兼容键名），用于非 Modify 场景
    private func buildCalendarJSONFromEventKit() async throws -> String {
        // 权限
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }

        guard authorized else { return try JSONSerialization.string(withJSONObject: ["日程": []]) }

    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    // 关怀功能：今天往前3天到往后3天，总共7天
    let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
    let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)

    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
    let finalEvents = eventStore.events(matching: predicate)
        return try buildStructuredScheduleJSON(from: finalEvents, dateRange: start...end, defaultScheduleType: nil)
    }

    // 从应用日历（界面层传入的 EKEvent 数组）构造 JSON - 关怀功能版本（7天）
    private func buildCalendarJSON(fromAppEvents events: [EKEvent]) throws -> String {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
        let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        return try buildStructuredScheduleJSON(from: events, dateRange: start...end, defaultScheduleType: nil)
    }

    // 从应用日历（界面层传入的 EKEvent 数组）构造 JSON - 快速创建专用版本（排除id和note）
    private func buildCalendarJSONForQuickCreate(fromAppEvents events: [EKEvent]) throws -> String {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
        let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        return try buildStructuredScheduleJSON(from: events, dateRange: start...end, defaultScheduleType: nil)
    }

    // 从应用日历（界面层传入的 EKEvent 数组）构造 JSON - 商业化推荐专用版本（5天）
    private func buildCalendarJSONForCommercial(fromAppEvents events: [EKEvent]) throws -> String {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-1*86400)
        let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        return try buildStructuredScheduleJSON(from: events, dateRange: start...end, defaultScheduleType: nil)
    }

    // 创建快速创建专用的EventKit日历JSON（排除id和note）
    private func buildCalendarJSONFromEventKitForQuickCreate() async throws -> String {
        // 权限
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }

        guard authorized else { return try JSONSerialization.string(withJSONObject: ["日程": []]) }

    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    // 快速创建：今天往前3天到往后3天，总共7天
    let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
    let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)

    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
    let finalEvents = eventStore.events(matching: predicate)
        return try buildStructuredScheduleJSON(from: finalEvents, dateRange: start...end, defaultScheduleType: nil)
    }

    // 创建商业化推荐专用的EventKit日历JSON
    private func buildCalendarJSONFromEventKitForCommercial() async throws -> String {
        // 权限
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }

        guard authorized else { return try JSONSerialization.string(withJSONObject: ["日程": []]) }

    let cal = Calendar.current
    let todayStart = cal.startOfDay(for: Date())
    // 商业化推荐：今天往前1天到往后3天，总共5天
    let start = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-1*86400)
    let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)

    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
    let finalEvents = eventStore.events(matching: predicate)
        return try buildStructuredScheduleJSON(from: finalEvents, dateRange: start...end, defaultScheduleType: nil)
    }
}

// 便捷：将字典编码为 JSON 字符串
private extension JSONSerialization {
    static func string(withJSONObject obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// 从系统日历生成中文自然语言描述
private extension OpenAIService {
    func buildNaturalLanguageScheduleFromEventKit(startOffsetDays: Int, endOffsetDays: Int, defaultScheduleType: String?) async throws -> String {
        // 权限（与现有实现保持一致）
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }
        guard authorized else { return "无日程" }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: startOffsetDays, to: todayStart) ?? todayStart.addingTimeInterval(Double(startOffsetDays) * 86400)
        let end = cal.date(byAdding: .day, value: endOffsetDays, to: todayStart) ?? todayStart.addingTimeInterval(Double(endOffsetDays) * 86400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
        return buildNaturalLanguageSchedule(from: events, dateRange: start...end, defaultScheduleType: defaultScheduleType)
    }

    func buildStructuredScheduleJSONFromEventKit(startOffsetDays: Int, endOffsetDays: Int, defaultScheduleType: String?) async throws -> String {
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }
        guard authorized else { return try JSONSerialization.string(withJSONObject: ["日程": []]) }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: startOffsetDays, to: todayStart) ?? todayStart.addingTimeInterval(Double(startOffsetDays) * 86400)
        let end = cal.date(byAdding: .day, value: endOffsetDays, to: todayStart) ?? todayStart.addingTimeInterval(Double(endOffsetDays) * 86400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
        return try buildStructuredScheduleJSON(from: events, dateRange: start...end, defaultScheduleType: defaultScheduleType)
    }

    func buildHARSlimScheduleJSONFromEventKit() async throws -> String {
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                _ = try? await eventStore.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    eventStore.requestAccess(to: EKEntityType.event) { _, _ in continuation.resume() }
                }
            }
        }
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess }
        else { authorized = EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized }
        guard authorized else { return try JSONSerialization.string(withJSONObject: ["日程": []]) }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -3, to: todayStart) ?? todayStart.addingTimeInterval(-3*86400)
        let end = cal.date(byAdding: .day, value: 3, to: todayStart) ?? todayStart.addingTimeInterval(3*86400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
        return try buildHARSlimScheduleJSON(from: events)
    }
}

// MARK: - Embedding Provider (DashScope)
extension OpenAIService: TextEmbeddingProvider {
    // 使用 DashScope 的 Embedding 能力：输入多段文本，返回对应向量
    // 注意：此功能已迁移到后端，此处抛出错误
    func embed(texts: [String]) async throws -> [[Double]] {
        // 嵌入功能已迁移到后端，不再在客户端直接调用
        throw EmbeddingError.migrationToBackend
    }
}

// MARK: - Embedding Error
enum EmbeddingError: Error, LocalizedError {
    case migrationToBackend

    var errorDescription: String? {
        switch self {
        case .migrationToBackend:
            return "嵌入功能已迁移到后端，请通过后端 API 使用"
        }
    }
}

// MARK: - Data Models
// 严格 JSON 返回提示语（商业化推荐）
private func enforceRecommendationsJSONPrompt(basePrompt: String) -> String {
    var p = basePrompt
    p += "\n\n请严格仅返回 JSON，不要附加任何解释或前后缀。返回格式如下：" +
    "{\"recommendations\":[{\"option_id\":number,\"recommendation_item\":{\"name\":string,\"category\":string,\"location_context\":string},\"persuasion_text\":string,\"conversion_funnel\":{\"call_to_action\":string},\"confidence_score\":number}]}" +
    "。其中 confidence_score 范围为 0.0-1.0。"
    return p
}

// 商业化推荐返回结构
struct CommercialRecommendationResponse: Codable {
    let recommendations: [CommercialRecommendationItem]?
}

struct CommercialRecommendationItem: Codable, Identifiable {
    struct RecommendationItem: Codable {
        let name: String?
        let category: String?
        let location_context: String?
    }
    struct ConversionFunnel: Codable {
        let call_to_action: String?
    }

    let option_id: Int?
    let recommendation_item: RecommendationItem?
    let persuasion_text: String?
    let conversion_funnel: ConversionFunnel?
    let confidence_score: Double?
    let suggestion_text: String?

    var id: String { String(option_id ?? Int.random(in: 1...999999)) + (recommendation_item?.name ?? UUID().uuidString) }
}

// 请求分析任务结构（供进度回调使用）
struct AnalysisTask: Codable {
    let operation: String
    let utterance: String
}
