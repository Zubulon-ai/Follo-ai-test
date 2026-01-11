import SwiftUI
import EventKit

struct AssistantChatView: View {
    let assistantDisplayName: String // 列表显示名
    let recipientName: String       // 代理人姓名（如 佳琛）

    @StateObject private var vc = VoiceChatService()
    @StateObject private var provider = CalendarEventProvider()
    @State private var notificationMessage: String?

    var body: some View {
        VoiceChatView(service: vc, titleOverride: nil, embedInNavigation: false)
            .navigationTitle(assistantDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { vc.clearMessages() }
                        .foregroundColor(.red)
                }
            }
            .task {
                // 注入 meeting 模式与上下文
                vc.aiMode = .meeting
                vc.meetingContextProvider = { VoiceChatService.MeetingContext(recipientName: recipientName,
                                                                              recipientPreferencesJSON: mockRecipientPreferencesJSON(),
                                                                              recipientCalendarJSON: mockRecipientCalendarJSON(),
                                                                              requesterName: "恒宇") }
                // 提供请求者（我方）上下文
                vc.userInfoProvider = { UserInfo(age: "26-35", profession: "产品经理", gender: "男") }
                vc.appCalendarEventsProvider = {
                    // 使用应用已有的事件窗口
                    let cal = Calendar.current
                    let todayStart = cal.startOfDay(for: Date())
                    let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart.addingTimeInterval(-7*86400)
                    let end = cal.date(byAdding: .day, value: 14, to: todayStart) ?? todayStart.addingTimeInterval(14*86400)
                    let all = provider.eventsByDay.values.flatMap { $0 }
                    return all.filter { ev in
                        guard let s = ev.startDate, let e = ev.endDate else { return false }
                        return (s <= end && e >= start)
                    }
                }
                await provider.requestAccessIfNeeded()
                if provider.hasReadAccess {
                    provider.ensureEventsLoaded(around: Date())
                    provider.select(date: Date())
                }

                // Listen for notification tap
                setupNotificationListener()
            }
            .onChange(of: notificationMessage) { newValue in
                if let message = newValue {
                    // Add notification message to chat
                    vc.addMessage(message, isUser: false)
                    ChatMessageStore.shared.clear()
                }
            }
    }

    private func setupNotificationListener() {
        NotificationCenter.default.addObserver(
            forName: .notificationTapped,
            object: nil,
            queue: .main
        ) { notification in
            if let fullMessage = notification.object as? [String: String] {
                notificationMessage = formatFullMessage(fullMessage)
            }
        }
    }

    private func formatFullMessage(_ message: [String: String]) -> String {
        let parts = [
            message["rationale"],
            message["anchor"],
            message["suggestion"],
            message["assurance"]
        ].compactMap { $0 }

        return parts.joined(separator: "\n\n")
    }


    // 直接使用 VoiceChatView(service:) 构造注入的服务实例
}

// MARK: - 模拟对方偏好与日程 JSON
private func mockRecipientPreferencesJSON() -> String {
    let dict: [String: Any] = [
        "work_hours": ["start": "09:30", "end": "18:30"],
        "meeting_preference": ["prefer": "afternoon", "duration": 45, "buffer": 15],
        "timezone": TimeZone.current.identifier
    ]
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) { return String(data: data, encoding: .utf8) ?? "{}" }
    return "{}"
}

private func mockRecipientCalendarJSON() -> String {
    // 结构化中文 JSON（按天、无id、中文键名）
    let cal = Calendar.current
    let fmtDay = DateFormatter()
    fmtDay.locale = Locale(identifier: "zh_CN")
    fmtDay.timeZone = TimeZone.current
    fmtDay.dateFormat = "M月d日"
    let today = cal.startOfDay(for: Date())
    let d1 = fmtDay.string(from: cal.date(byAdding: .day, value: 1, to: today) ?? today)
    let payload: [String: Any] = [
        "日程": [
            [
                "日期": d1,
                "事件": [
                    [
                        "时间": "09:00-10:00",
                        "标题": "项目同步",
                        "地点": "线上会议",
                        "备注": "请提前查看材料",
                        "日程类型": "对方工作日程",
                        "开始": ISO8601DateFormatter().string(from: today.addingTimeInterval(86400 + 9*3600)),
                        "结束": ISO8601DateFormatter().string(from: today.addingTimeInterval(86400 + 10*3600)),
                        "是否全天": false,
                        "时区": TimeZone.current.identifier
                    ]
                ]
            ]
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) { return String(data: data, encoding: .utf8) ?? "{}" }
    return "{}"
}
