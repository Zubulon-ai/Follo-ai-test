import SwiftUI

struct QuickCreateView: View {
    @StateObject private var vc = VoiceChatService()
    @StateObject private var provider = CalendarEventProvider()
    @State private var navigateToDay: Bool = false
    @State private var targetDayDate: Date? = nil
    @State private var highlightEventId: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if vc.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("语音转文字中…")
                        .foregroundColor(.secondary)
                }
            }

            // 大号录音按钮（按住开始、松开结束）
            ZStack {
                Circle()
                    .fill(vc.isRecording ? Color.red : Color.blue)
                    .frame(width: 180, height: 180)
                Text(vc.isRecording ? "松开结束" : "按住说话")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !vc.isRecording && !(vc.isAIResponding || vc.isTranscribing) {
                            vc.startVoiceRecording()
                        }
                    }
                    .onEnded { _ in
                        if vc.isRecording {
                            vc.stopVoiceRecording()
                        }
                    }
            )
            .disabled(vc.isAIResponding || vc.isTranscribing)
            .scaleEffect(vc.isRecording ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: vc.isRecording)

            if vc.isAIResponding {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("AI 正在生成…")
                        .foregroundColor(.secondary)
                }
            }

            // 展示最近一条 AI 消息里的操作摘要（与 Follo 聊天一致的解析/展示组件）
            if let lastAI = vc.messages.last(where: { !$0.isUser }) {
                // 总是显示AI回复内容
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI 回复")
                        .font(.headline)
                    Text(lastAI.content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(10)

                    // 如果有操作结果，额外显示操作结果
                    if let ops = lastAI.appliedOps, !ops.isEmpty {
                        Divider()
                        Text("操作结果")
                            .font(.headline)
                        AppliedOpsList(ops: ops)
                        // 若存在创建成功的项，提供直接跳转入口
                        if let create = ops.first(where: { $0.operation.uppercased() == "CREATE" && $0.success }) {
                            CreatedEventCard(summary: create) { openEventDetail(using: create) }
                        }
                    }
                }
                .padding(.horizontal)
            } else {
                Text("说出你的日程需求，我会帮你快速创建！")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("快速创建")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            // 切换到 quickCreate 模式并注入上下文
            vc.aiMode = .quickCreate
            vc.userInfoProvider = { UserInfo(age: "26-35", profession: "产品经理", gender: "男") }
            vc.appCalendarEventsProvider = {
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
        }
        .navigationDestination(isPresented: $navigateToDay) {
            DayViewScreen(
                provider: provider,
                date: Calendar.current.startOfDay(for: targetDayDate ?? Date()),
                highlightEventId: highlightEventId
            )
        }
        // 友好提示弹窗（短语音/未识别）
        .alert(vc.friendlyAlertState?.title ?? "提示",
               isPresented: Binding(
                get: { vc.friendlyAlertState != nil },
                set: { if !$0 { vc.friendlyAlertState = nil } }
               )
        ) {
            Button("好的", role: .cancel) { vc.friendlyAlertState = nil }
        } message: {
            Text(vc.friendlyAlertState?.message ?? "")
        }
    }


    private func openEventDetail(using s: AppliedOperationSummary) {
        // 跳转到该事件所在日并高亮该事件
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        if let startStr = s.startTime, let d = iso.date(from: startStr) {
            // 先刷新当前范围，以免刚创建的事件还未进入缓存
            let end = d.addingTimeInterval(3600)
            provider.refreshDays(from: d, to: end)
            provider.select(date: d)
            targetDayDate = d
            highlightEventId = s.targetEventId
            navigateToDay = true
        }
    }
}

// MARK: - Created Event Card
private struct CreatedEventCard: View {
    let summary: AppliedOperationSummary
    var onTap: () -> Void

    private let iso = ISO8601DateFormatter()

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.purple)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title ?? "新建日程")
                        .font(.headline)
                    Text(timeRange())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.purple.opacity(0.08))
            .cornerRadius(12)
        }
    }

    private func timeRange() -> String {
        iso.timeZone = TimeZone.current
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        guard let s = summary.startTime, let e = summary.endTime,
              let sd = iso.string(from: iso.date(from: s) ?? Date()).data(using: .utf8).flatMap({ _ in iso.date(from: s) }),
              let ed = iso.date(from: e) else { return "--" }
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
        let f2 = DateFormatter(); f2.dateFormat = "HH:mm"
        return "\(f.string(from: sd)) - \(f2.string(from: ed))"
    }
}
