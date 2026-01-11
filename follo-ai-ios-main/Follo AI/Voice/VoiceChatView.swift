//
//  VoiceChatView.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/8/13.
//

import SwiftUI
import Combine
import UIKit

struct VoiceChatView: View {
    @StateObject private var voiceChatService: VoiceChatService
    private let embedInNavigation: Bool
    private let titleOverride: String?
    private let prefillSuggestion: String?
    private let prefillSecond: String?
    private let prefillThird: String?
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var calendarProvider = CalendarEventProvider()
    @State private var navigateToDay: Bool = false
    @State private var targetDayDate: Date? = nil
    @State private var highlightEventId: String? = nil
    @State private var deepLinkEventId: String? = nil
    @State private var showClearConfirm: Bool = false
    @State private var showingPermissionAlert = false
    @State private var inputText = ""
    @State private var inputMode: InputMode = .voice // 默认语音模式
    @FocusState private var isTextFieldFocused: Bool
    // 粘贴面板状态
    @State private var pasteText: String = ""
    @State private var showPasteSuggestion: Bool = false
    @State private var pasteSuggestionDismissed: Bool = false
    @State private var showPastePanel: Bool = false
    // AI 思考提示语轮播
    @State private var thinkingMessageIndex: Int = 0
    private let thinkingMessages: [String] = [
        "Follo正在完成日程调度…",
        "Follo在梳理可行的时间窗口…",
        "Follo在对齐参与者日程与偏好…",
        "Follo在检查冲突并优化安排…",
        "Follo在确认与日历的同步细节…"
    ]
    private let thinkingTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    // 导出聊天记录
    @State private var showExportSheet: Bool = false
    @State private var exportFileURL: URL? = nil
    @State private var showExportSuccess: Bool = false
    
    enum InputMode {
        case text
        case voice
    }
    
    private var hasUserRequest: Bool {
        return voiceChatService.messages.contains { $0.isUser }
    }
    
    var body: some View {
        Group {
            if embedInNavigation {
                NavigationView {
                    mainContent
                        .navigationTitle(titleOverride ?? "Follo AI 日程管理")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .toolbar {
                            // 显示粘贴面板按钮（仅在无用户请求时显示）
                            if !hasUserRequest {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button {
                                        withAnimation { showPastePanel.toggle() }
                                    } label: {
                                        Image(systemName: "doc.append")
                                    }
                                }
                            }
                            // 保存/导出聊天记录按钮
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    exportChatHistory()
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .disabled(voiceChatService.messages.isEmpty)
                            }
                            // 删除仅保留图标
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    showClearConfirm = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(voiceChatService.messages.isEmpty)
                            }
                        }
                }
            } else {
                mainContent
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaInset(edge: .bottom) { bottomInputArea }
        .safeAreaInset(edge: .top) { topBarInset }
        .onAppear {
            // 将 DataManager 的最近状态数据（含持久化回退）提供给语音服务，用于 Sensor.records
            voiceChatService.recentStatusDataProvider = { dataManager.getLatest3StatusDataIncludingPersisted() }
            // 将应用内日历事件提供给语音服务，窗口为[-7, +14]天
            voiceChatService.appCalendarEventsProvider = {
                let cal = Calendar.current
                let todayStart = cal.startOfDay(for: Date())
                let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart.addingTimeInterval(-7*86400)
                let end = cal.date(byAdding: .day, value: 14, to: todayStart) ?? todayStart.addingTimeInterval(14*86400)
                // 展开 provider.eventsByDay 到数组，并按时间过滤交集
                let all = calendarProvider.eventsByDay.values.flatMap { $0 }
                let filtered = all.filter { ev in
                    guard let s = ev.startDate, let e = ev.endDate else { return false }
                    return (s <= end && e >= start)
                }
                return filtered
            }
            // 可选：注入用户信息（若后续有用户信息表单/设置，可在此处提供）
            voiceChatService.userInfoProvider = { nil }
            Task {
                // 先请求权限，再预加载事件，并确保选中今天，避免首次为空
                await calendarProvider.requestAccessIfNeeded()
                if calendarProvider.hasReadAccess {
                    calendarProvider.ensureEventsLoaded(around: Date())
                    calendarProvider.select(date: Date())
                }
            }
            // 如有预填建议，作为第一/第二/第三条 AI 消息加入
            if voiceChatService.messages.isEmpty {
                if let s1 = prefillSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines), !s1.isEmpty {
                    let ai1 = VoiceMessage(content: s1, isUser: false, timestamp: Date(), messageType: .text)
                    voiceChatService.messages.append(ai1)
                }
                if let s2 = prefillSecond?.trimmingCharacters(in: .whitespacesAndNewlines), !s2.isEmpty {
                    let ai2 = VoiceMessage(content: s2, isUser: false, timestamp: Date(), messageType: .text)
                    voiceChatService.messages.append(ai2)
                }
                if let s3 = prefillThird?.trimmingCharacters(in: .whitespacesAndNewlines), !s3.isEmpty {
                    let ai3 = VoiceMessage(content: s3, isUser: false, timestamp: Date(), messageType: .text)
                    voiceChatService.messages.append(ai3)
                }
            }
            // 非侵入式：仅在尚无用户请求时评估剪贴板
            evaluateClipboard()
        }
        .statusBarHidden(false)
        .onReceive(NotificationCenter.default.publisher(for: .voiceChatNavigateToDay)) { note in
            if let date = note.userInfo?["date"] as? Date {
                targetDayDate = date
                calendarProvider.select(date: date)
            }
            if let eid = note.userInfo?["eventId"] as? String {
                highlightEventId = eid
            } else {
                highlightEventId = nil
            }
            navigateToDay = true
        }
        .onChange(of: voiceChatService.isAIResponding) {
            // 每次进入思考状态时从第一条提示语开始
            if voiceChatService.isAIResponding { thinkingMessageIndex = 0 }
        }
        .navigationDestination(isPresented: $navigateToDay) {
            DayViewScreen(
                provider: calendarProvider,
                date: Calendar.current.startOfDay(for: targetDayDate ?? Date()),
                highlightEventId: highlightEventId
            )
        }
        .alert("需要权限", isPresented: $showingPermissionAlert) {
            Button("设置") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请在设置中允许访问麦克风和语音识别功能")
        }
        // 短语音/未识别等友好提示弹窗
        .alert(voiceChatService.friendlyAlertState?.title ?? "提示",
               isPresented: Binding(
                get: { voiceChatService.friendlyAlertState != nil },
                set: { if !$0 { voiceChatService.friendlyAlertState = nil } }
               )
        ) {
            Button("好的", role: .cancel) {
                voiceChatService.friendlyAlertState = nil
            }
        } message: {
            Text(voiceChatService.friendlyAlertState?.message ?? "")
        }
        // 清空聊天记录确认
        .confirmationDialog("删除所有聊天记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                voiceChatService.clearMessages()
            }
            Button("取消", role: .cancel) { }
        }
        // 导出聊天记录分享
        .sheet(isPresented: $showExportSheet) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        // 导出成功提示
        .alert("导出成功", isPresented: $showExportSuccess) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("聊天记录已保存，您可以选择分享或保存到文件")
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // 聊天消息列表
            chatMessagesList
                .simultaneousGesture(TapGesture().onEnded {
                    // 点击聊天区域时收起键盘（不拦截子视图点击）
                    isTextFieldFocused = false
                })
        }
    }

    // MARK: - Initializers
    init(titleOverride: String? = nil, embedInNavigation: Bool = true, prefillSuggestion: String? = nil, prefillSecond: String? = nil, prefillThird: String? = nil) {
        _voiceChatService = StateObject(wrappedValue: VoiceChatService())
        self.titleOverride = titleOverride
        self.embedInNavigation = embedInNavigation
        self.prefillSuggestion = prefillSuggestion
        self.prefillSecond = prefillSecond
        self.prefillThird = prefillThird
    }

    init(service: VoiceChatService, titleOverride: String? = nil, embedInNavigation: Bool = true, prefillSuggestion: String? = nil, prefillSecond: String? = nil, prefillThird: String? = nil) {
        _voiceChatService = StateObject(wrappedValue: service)
        self.titleOverride = titleOverride
        self.embedInNavigation = embedInNavigation
        self.prefillSuggestion = prefillSuggestion
        self.prefillSecond = prefillSecond
        self.prefillThird = prefillThird
    }
    
    // MARK: - 聊天消息列表
    private var chatMessagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // 粗识别剪贴板提示：独立于面板，不随面板隐藏
                    if showPasteSuggestion && !pasteSuggestionDismissed {
                        clipboardSuggestionChip
                    }
                    // 点击按钮后显示粘贴面板（用户有请求后自动隐藏）
                    if showPastePanel && !hasUserRequest {
                        pastePanel
                    }
                    if voiceChatService.messages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(voiceChatService.messages) { message in
                            ChatMessageRow(
                                message: message,
                                voiceChatService: voiceChatService,
                                onCreateEvent: { suggestion in
                                    createEvent(from: suggestion)
                                },
                                onOpenDay: { date in
                                    openDay(for: date)
                                }
                            )
                    // 修改/删除候选确认卡片
                    if let ctx = message.modifyConfirm {
                        ModifyConfirmCard(context: ctx) { chosenId, occurrenceStart in
                            voiceChatService.confirmModify(action: ctx.action, candidateId: chosenId, occurrenceStart: occurrenceStart, changes: ctx.changes)
                        }
                    }
                            if let mr = message.meetingResult, let options = mr.proposed_options, !options.isEmpty {
                                MeetingOptionsCard(result: mr) { selected in
                                    // 选择后直接创建日历事件并跳转到该事件日视图
                                    guard let startIso = selected.startTime,
                                          let start = ISO8601DateFormatter().date(from: startIso) else { return }
                                    let endIso: String
                                    if let providedEnd = selected.endTime, let _ = ISO8601DateFormatter().date(from: providedEnd) {
                                        endIso = providedEnd
                                    } else {
                                        // 若模型未提供 endTime，则依据 meeting_details.duration 进行推算（默认 60 分钟）
                                        let minutes = mr.meeting_details?.duration ?? 60
                                        let endDate = Calendar.current.date(byAdding: .minute, value: minutes, to: start) ?? start.addingTimeInterval(Double(minutes) * 60)
                                        endIso = ISO8601DateFormatter().string(from: endDate)
                                    }
                                    let end = ISO8601DateFormatter().date(from: endIso) ?? start.addingTimeInterval(3600)
                                    let suggestion = AIScheduleSuggestion(
                                        title: mr.meeting_details?.title ?? "会议",
                                        startTime: startIso,
                                        endTime: endIso,
                                        duration: Int(end.timeIntervalSince(start)/60),
                                        location: nil,
                                        tags: nil,
                                        status: nil,
                                        ai_metadata: .init(confidence_score: nil, reasoning: selected.reasoning, response: nil)
                                    )
                                    createEvent(from: suggestion)
                                }
                            }
                        }
                    }
                    
                    // AI 正在回复的指示器
                    if voiceChatService.isAIResponding {
                        aiTypingIndicator
                    }
                    // 底部锚点：用于保证滚动到最底部（包括思考指示器）
                    Color.clear
                        .frame(height: 1)
                        .id("scrollBottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: voiceChatService.messages.count) {
                // 自动滚动到底部（包括思考指示器）
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("scrollBottom", anchor: .bottom)
                }
            }
            .onChange(of: voiceChatService.isAIResponding) {
                // 当进入思考状态时，确保滚动到最底部显示指示器
                guard voiceChatService.isAIResponding else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("scrollBottom", anchor: .bottom)
                }
            }
        }
    }
    
    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "calendar")
                .font(.system(size: 80))
                .foregroundColor(.blue.opacity(0.6))
            
            Text("开始你的日程管理")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.gray)
            
            Text("与Follo AI聊天，日程安排变得如此简单")
                .font(.body)
                .foregroundColor(.gray.opacity(0.8))
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - AI 正在回复指示器
    private var aiTypingIndicator: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .foregroundColor(.purple)
                
                Text(thinkingMessages[thinkingMessageIndex])
                    .font(.body)
                    .foregroundColor(.secondary)
                
                // 动画点点（轮流跳动）
                TimelineView(.animation) { context in
                    let period: Double = 1.2
                    let amplitude: CGFloat = 4
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2) {
                        ForEach(0..<3) { i in
                            let phase = (t + Double(i) * 0.2).truncatingRemainder(dividingBy: period) / period
                            let y = voiceChatService.isAIResponding ? -abs(sin(phase * .pi * 2)) * amplitude : 0
                            Circle()
                                .frame(width: 4, height: 4)
                                .foregroundColor(.purple.opacity(0.8))
                                .offset(y: y)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(16)
            .onReceive(thinkingTimer) { _ in
                guard voiceChatService.isAIResponding else { return }
                thinkingMessageIndex = (thinkingMessageIndex + 1) % max(thinkingMessages.count, 1)
            }
            
            Spacer()
        }
    }
    
    // MARK: - 底部输入区域
    private var bottomInputArea: some View {
        VStack(spacing: 0) {
            Divider()
            
            // 语音转文字状态指示器
            if voiceChatService.isTranscribing {
                transcribingIndicator
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                // 主输入区域
                mainInputArea
                
                // 发送按钮或加号按钮
                sendOrAddButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
        }
    }
    
    // MARK: - 语音转文字指示器
    private var transcribingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            
            Text("语音转文字中...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 主输入区域
    private var mainInputArea: some View {
        HStack(spacing: 0) {
            if inputMode == .text {
                // 文字输入框
                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .focused($isTextFieldFocused)
                    .lineLimit(1...5) // 最多5行
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
                    .cornerRadius(20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.3), lineWidth: 1)
                    )
                    .onSubmit {
                        // 回车键发送消息
                        sendTextMessage()
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            inputMode = .text
                        }
                    }
            } else {
                // 语音输入按钮（按住说话：按下开始、松开结束）
                HStack {
                    Spacer()
                    
                    if voiceChatService.isRecording {
                        Text("松开 结束")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .medium))
                    } else {
                        Text("按住 说话")
                            .foregroundColor(.primary)
                            .font(.system(size: 16, weight: .medium))
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(voiceChatService.isRecording ? Color.red : (colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(voiceChatService.isRecording ? Color.red : Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.3), lineWidth: 1)
                )
                .scaleEffect(voiceChatService.isRecording ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: voiceChatService.isRecording)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !voiceChatService.isRecording && !(voiceChatService.isTranscribing || voiceChatService.isAIResponding) {
                                voiceChatService.startVoiceRecording()
                            }
                        }
                        .onEnded { _ in
                            if voiceChatService.isRecording {
                                voiceChatService.stopVoiceRecording()
                            }
                        }
                )
                .disabled(voiceChatService.isTranscribing || voiceChatService.isAIResponding)
                .opacity((voiceChatService.isTranscribing || voiceChatService.isAIResponding) ? 0.6 : 1.0)
            }
        }
        .frame(minHeight: 40)
    }
    
    // MARK: - 发送或加号按钮
    private var sendOrAddButton: some View {
        Button(action: {
            if inputMode == .text && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 发送文字消息
                sendTextMessage()
            } else {
                // 切换到语音模式
                withAnimation(.easeInOut(duration: 0.2)) {
                    inputMode = inputMode == .text ? .voice : .text
                    if inputMode == .text {
                        isTextFieldFocused = true
                    } else {
                        isTextFieldFocused = false
                    }
                }
            }
        }) {
            Group {
                if inputMode == .text && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 发送按钮
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                } else {
                    // 语音/文字切换按钮
                    Image(systemName: inputMode == .text ? "mic.fill" : "keyboard.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
            }
        }
        .disabled(voiceChatService.isAIResponding)
    }
    
    // MARK: - 发送文字消息
    private func sendTextMessage() {
        let messageText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        
        // 清空输入框
        inputText = ""
        
        // 创建文字消息
        let textMessage = VoiceMessage(
            content: messageText,
            isUser: true,
            timestamp: Date(),
            messageType: .text,
            audioFileURL: nil,
            audioDuration: nil
        )
        
        // 添加到消息列表
        voiceChatService.messages.append(textMessage)
        
        // 发送给AI
        voiceChatService.sendToAI(message: messageText)
    }

    // MARK: - 发送粘贴文本为首条请求
    private func sendPastedText() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 将粘贴内容作为用户首条消息发送
        let message = VoiceMessage(
            content: text,
            isUser: true,
            timestamp: Date(),
            messageType: .text,
            audioFileURL: nil,
            audioDuration: nil
        )
        voiceChatService.messages.append(message)
        // 立即调用现有 AI 主流程
        voiceChatService.sendToAI(message: text)
        // 成功发送后清空粘贴区并隐藏提示
        pasteText = ""
        showPasteSuggestion = false
        pasteSuggestionDismissed = true
        showPastePanel = false
    }

    // MARK: - 剪贴板启发式
    private func evaluateClipboard() {
        guard !hasUserRequest else { return }
        guard UIPasteboard.general.hasStrings, let s = UIPasteboard.general.string, !pasteSuggestionDismissed else { return }
        showPasteSuggestion = looksLikeInvite(s)
    }

    private func looksLikeInvite(_ s: String) -> Bool {
        let lowered = s.lowercased()
        let regex = try? NSRegularExpression(pattern: "(\\b[01]?[0-9]|2[0-3]):[0-5][0-9]|明天|后天|周[一二三四五六日天]|下周")
        let hasTime = regex?.firstMatch(in: lowered, range: NSRange(location: 0, length: (lowered as NSString).length)) != nil
        let hasLink = lowered.contains("zoom") || lowered.contains("meet.google") || lowered.contains("teams")
        let hasKeywords = lowered.contains("会议") || lowered.contains("邀请") || lowered.contains("行程") || lowered.contains("通知")
        return (hasTime && hasKeywords) || hasLink
    }
}

// MARK: - 顶部栏（未嵌入导航时显示）
extension VoiceChatView {
    @ViewBuilder
    private var topBarInset: some View {
        if !embedInNavigation {
            topBar
        }
    }

    // MARK: - 粘贴并解析面板
    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pasteText)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.3), lineWidth: 1)
                    )
                if pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("粘贴邮件/会议邀请/通知内容，我来帮你生成日程…")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            HStack {
                Button {
                    if let s = UIPasteboard.general.string {
                        pasteText = s
                    }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    sendPastedText()
                } label: {
                    Label("解析为日程", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceChatService.isAIResponding)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 剪贴板提示 Chip（独立显示）
    private var clipboardSuggestionChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundColor(.blue)
            Text("发现剪贴板可能是邀请，粘贴并解析？")
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                if let s = UIPasteboard.general.string { pasteText = s }
                withAnimation { showPastePanel = true }
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            Button(action: { pasteSuggestionDismissed = true }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(10)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(titleOverride ?? "Follo AI 日程管理")
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            if !hasUserRequest {
                Button {
                    withAnimation { showPastePanel.toggle() }
                } label: {
                    Image(systemName: "doc.append")
                }
            }
            // 保存/导出聊天记录
            Button {
                exportChatHistory()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(voiceChatService.messages.isEmpty)
            // 清空记录
            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(voiceChatService.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

// MARK: - 会议建议卡片 UI
private struct MeetingOptionsCard: View {
    let result: MeetingAssistantResult
    var onSelect: (MeetingAssistantResult.ProposedOption) -> Void

    private let iso = ISO8601DateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = result.meeting_details {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = d.title, !title.isEmpty {
                        Text(title).font(.headline)
                    }
                    HStack(spacing: 12) {
                        if let dur = d.duration { Label("时长: \(dur) 分钟", systemImage: "clock") }
                        if let people = d.attendees, !people.isEmpty { Label("参会: \(people.joined(separator: ", "))", systemImage: "person.2") }
                    }.font(.caption).foregroundColor(.secondary)
                }
            }
            if let opts = result.proposed_options {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(opts) { op in
                        Button {
                            onSelect(op)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("#\(op.option_id ?? 0)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(timeRange(op))
                                        .font(.subheadline)
                                    if let reason = op.reasoning, !reason.isEmpty {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: "lightbulb.fill").foregroundColor(.orange)
                                            Text(reason)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }
                            .padding(10)
                            .background(Color.accentColor.opacity(0.06))
                            .cornerRadius(10)
                        }
                    }
                }
            }
            // 不再显示 response 字段
        }
        .padding(12)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(12)
    }

    private func timeRange(_ op: MeetingAssistantResult.ProposedOption) -> String {
        guard let s = op.startTime, let e = op.endTime,
              let sd = iso.date(from: s), let ed = iso.date(from: e) else {
            return "--"
        }
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        let f2 = DateFormatter()
        f2.dateFormat = "HH:mm"
        return "\(f.string(from: sd)) - \(f2.string(from: ed))"
    }
}

// MARK: - 自定义气泡形状
struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: isUser ? 
                [.topLeft, .topRight, .bottomLeft] : 
                [.topLeft, .topRight, .bottomRight],
            cornerRadii: CGSize(width: 18, height: 18)
        )
        return Path(path.cgPath)
    }
}

// MARK: - 聊天消息行组件
struct ChatMessageRow: View {
    let message: VoiceMessage
    let voiceChatService: VoiceChatService
    var onCreateEvent: ((AIScheduleSuggestion) -> Void)? = nil
    var onOpenDay: ((Date) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                userMessageView
            } else {
                aiMessageView
                Spacer()
            }
        }
    }
    
    // MARK: - 用户消息视图
    private var userMessageView: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if message.messageType == .voice {
                voiceMessageBubble(isUser: true)
            } else {
                textMessageBubble(text: message.content, isUser: true)
            }
            
            Text(formatTimestamp(message.timestamp))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: .trailing)
    }
    
    // MARK: - AI 消息视图
    private var aiMessageView: some View {
        HStack(alignment: .top, spacing: 8) {
            // AI 头像
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundColor(.purple)
                .frame(width: 32, height: 32)
                .background(Color.purple.opacity(0.1))
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 6) {
                textMessageBubble(text: message.content, isUser: false)
                
                // 直连模式：显示 Agent A 标签
                if let tags = message.agentATags, !tags.isEmpty {
                    AgentATagsView(tags: tags)
                }
                
                // 直连模式：显示 Agent B 通知
                if let notifications = message.agentBNotifications, !notifications.isEmpty {
                    AgentBNotificationsView(notifications: notifications)
                }
                
                // 直连模式：折叠的调试信息
                if let debugInfo = message.directModeDebugInfo, !debugInfo.isEmpty {
                    DirectModeDebugView(debugInfo: debugInfo)
                }
                
                if let ops = message.appliedOps, !ops.isEmpty {
                    AppliedOpsList(ops: ops) { r in
                        if r.success, let s = r.startTime, let d = parseIsoStable(s) {
                            let userInfo: [String: Any] = [
                                "date": d,
                                "eventId": (r.operation.uppercased() == "DELETE" ? nil : r.targetEventId) as Any
                            ]
                            NotificationCenter.default.post(name: .voiceChatNavigateToDay, object: nil, userInfo: userInfo)
                        }
                    }
                }
                if let sug = message.scheduleSuggestion, let resp = sug.ai_metadata?.response, !resp.isEmpty {
                    SuggestionCard(suggestion: sug, onCreateEvent: onCreateEvent, onOpenDay: onOpenDay)
                }
                
                Text(formatTimestamp(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: .leading)
    }
    
    // MARK: - 语音消息气泡
    private func voiceMessageBubble(isUser: Bool) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            // 音频播放区域
            Button(action: {
                if let playingId = voiceChatService.playingMessageId,
                   playingId == message.id {
                    voiceChatService.stopPlaying()
                } else {
                    voiceChatService.playVoiceMessage(message)
                }
            }) {
                HStack(spacing: 8) {
                    // 播放按钮
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(isUser ? .white : .blue)
                    
                    // 波形图标
                    Image(systemName: "waveform")
                        .font(.body)
                        .foregroundColor(isUser ? .white.opacity(0.8) : .blue.opacity(0.8))
                    
                    // 时长
                    if let duration = message.audioDuration {
                        Text(voiceChatService.formatDuration(duration))
                            .font(.caption)
                            .foregroundColor(isUser ? .white.opacity(0.9) : .blue.opacity(0.9))
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: adaptiveVoiceWidth)
                .background(isUser ? Color.blue : (colorScheme == .dark ? Color(.secondarySystemBackground) : Color.gray.opacity(0.2)))
                .cornerRadius(18)
            }
            
            // 语音识别内容文本框
            if !message.content.isEmpty {
                VStack(spacing: 4) {
                    Text("识别结果:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(colorScheme == .dark ? 0.15 : 0.3), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: adaptiveVoiceWidth)
            }
        }
    }
    
    // MARK: - 文本消息气泡
    private func textMessageBubble(text: String, isUser: Bool) -> some View {
        let bubbleColor: Color = isUser ? Color.blue : (colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
        return Text(text)
            .font(.body)
            .foregroundColor(isUser ? .white : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                // 自适应背景形状
                BubbleShape(isUser: isUser)
                    .fill(bubbleColor)
                    .shadow(
                        color: Color.black.opacity(0.1),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            )
            .frame(maxWidth: UIScreen.main.bounds.width * 0.7, alignment: isUser ? .trailing : .leading)
    }
    
    // MARK: - 播放状态
    private var isPlaying: Bool {
        voiceChatService.playingMessageId == message.id && voiceChatService.isPlaying
    }
    
    // MARK: - 自适应语音条宽度
    private var adaptiveVoiceWidth: CGFloat {
        guard let duration = message.audioDuration else { return 120 }
        
        // 基础宽度120，每秒增加15宽度，最小120，最大280
        let baseWidth: CGFloat = 120
        let widthPerSecond: CGFloat = 15
        let maxWidth: CGFloat = 280
        
        let calculatedWidth = baseWidth + (CGFloat(duration) * widthPerSecond)
        return min(maxWidth, max(baseWidth, calculatedWidth))
    }
    
    // MARK: - 时间格式化
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// 展示已执行的操作结果：对 UPDATE 和 DELETE 区分样式
struct AppliedOpsList: View {
    let ops: [AppliedOperationSummary]
    var onTap: ((AppliedOperationSummary) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ops) { r in
                OperationEventCard(summary: r) {
                    if let action = onTap { action(r) }
                    else if r.success, let s = r.startTime, let d = parseIsoStable(s) {
                        let userInfo: [String: Any] = [
                            "date": d,
                            "eventId": (r.operation.uppercased() == "DELETE" ? nil : r.targetEventId) as Any
                        ]
                        NotificationCenter.default.post(name: .voiceChatNavigateToDay, object: nil, userInfo: userInfo)
                    }
                }
            }
        }
    }

    private func backgroundColor(for r: AppliedOperationSummary) -> Color {
        let op = r.operation.uppercased()
        if !r.success { return Color.red.opacity(0.08) }
        switch op {
        case "DELETE": return Color.red.opacity(0.08)
        case "UPDATE": return Color.orange.opacity(0.08)
        default: return Color.green.opacity(0.08)
        }
    }

    private func summaryText(_ r: AppliedOperationSummary) -> String {
        if !r.success { return r.message ?? "操作失败" }
        let title = r.title ?? "(无标题)"
        switch r.operation.uppercased() {
        case "CREATE":
            return "已创建：\(title)"
        case "UPDATE":
            return "已修改：\(title)"
        case "DELETE":
            return "已删除：\(title)"
        default:
            return "已处理：\(title)"
        }
    }
}

// MARK: - Operation Event Card (统一三种操作的卡片样式)
private struct OperationEventCard: View {
    let summary: AppliedOperationSummary
    var onTap: () -> Void

    private var opUpper: String { summary.operation.uppercased() }
    private var tintColor: Color {
        switch opUpper {
        case "DELETE": return Color.red
        case "UPDATE": return Color.orange
        default: return Color.green
        }
    }
    private var iconName: String {
        switch opUpper {
        case "DELETE": return "trash.fill"
        case "UPDATE": return "pencil"
        default: return "plus.circle.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundColor(tintColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title ?? (opUpper == "DELETE" ? "已删除日程" : (opUpper == "UPDATE" ? "已修改日程" : "新建日程")))
                        .font(.headline)
                    Text(timeRangeStable(start: summary.startTime ?? "", end: summary.endTime ?? ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(12)
            .background(tintColor.opacity(0.08))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 建议卡片
private struct SuggestionCard: View {
    let suggestion: AIScheduleSuggestion
    var onCreateEvent: ((AIScheduleSuggestion) -> Void)? = nil
    var onOpenDay: ((Date) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "plus.circle")
                    .foregroundColor(.purple)
                Text("AI 建议日程")
                    .font(.subheadline.weight(.semibold))
            }
            if let title = suggestion.title { Text(title).font(.headline) }
            if let startStr = suggestion.startTime, let endStr = suggestion.endTime,
               let start = ISO8601DateFormatter().date(from: startStr),
               let end = ISO8601DateFormatter().date(from: endStr) {
                Text("时间：" + timeRange(start: start, end: end))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Button {
                        onCreateEvent?(suggestion)
                    } label: {
                        Label("添加到日历", systemImage: "plus")
                    }
                    Button {
                        onOpenDay?(start)
                    } label: {
                        Label("查看日视图", systemImage: "rectangle.grid.1x2")
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(12)
    }

    private func timeRange(start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        let f2 = DateFormatter()
        f2.dateFormat = "HH:mm"
        return "\(f.string(from: start)) - \(f2.string(from: end))"
    }
}

// MARK: - 修改/删除候选确认卡片
private struct ModifyConfirmCard: View {
    let context: ModifyConfirmContext
    var onChoose: (String, Date?) -> Void
    @State private var actedKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: context.action == "DELETE" ? "trash" : "pencil")
                    .foregroundColor(context.action == "DELETE" ? .red : .orange)
                Text(context.action == "DELETE" ? "请选择要删除的日程" : "请选择要修改的日程")
                    .font(.subheadline.weight(.semibold))
            }

            if context.action == "UPDATE", let ch = context.changes {
                ChangesPreview(changes: ch)
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(10)
            }

            if context.candidates.isEmpty {
                Text("未定位到相关日程，请补充时间或标题等信息。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(context.candidates) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.title.isEmpty ? "(无标题)" : c.title)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(timeRangeStable(start: c.start, end: c.end))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            if let loc = c.location, !loc.isEmpty {
                                Label(loc, systemImage: "mappin.and.ellipse")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(c.calendarTitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            let key = c.id + "|" + c.start
                            Button {
                                actedKeys.insert(key)
                                let occStart = parseIsoStable(c.start)
                                onChoose(c.id, occStart)
                            } label: {
                                if context.action == "DELETE" && actedKeys.contains(key) {
                                    Label("已删除", systemImage: "checkmark")
                                } else {
                                    Label(context.action == "DELETE" ? "删除" : "确认修改", systemImage: context.action == "DELETE" ? "trash" : "checkmark")
                                }
                            }
                            .font(.caption)
                            .disabled(context.action == "DELETE" && actedKeys.contains(key))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let s = parseIsoStable(c.start) {
                            let userInfo: [String: Any] = [
                                "date": s,
                                "eventId": c.id
                            ]
                            NotificationCenter.default.post(name: .voiceChatNavigateToDay, object: nil, userInfo: userInfo)
                        }
                    }
                    .padding(10)
                    .background(context.action == "DELETE" ? Color.red.opacity(0.06) : Color.orange.opacity(0.06))
                    .cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func timeRange(start: String, end: String) -> String {
        guard let s = parseIsoStable(start), let e = parseIsoStable(end) else { return "" }
        let df1 = DateFormatter()
        df1.dateFormat = "M月d日 HH:mm"
        let df2 = DateFormatter()
        df2.dateFormat = "HH:mm"
        return "\(df1.string(from: s)) - \(df2.string(from: e))"
    }
}
// MARK: - ISO8601 解析兜底（含毫秒/时区）
private func parseIsoStable(_ text: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.timeZone = TimeZone.current
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
    if let d = f1.date(from: text) { return d }
    let f2 = ISO8601DateFormatter()
    f2.timeZone = TimeZone.current
    f2.formatOptions = [.withInternetDateTime, .withTimeZone]
    if let d = f2.date(from: text) { return d }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    if let d = df.date(from: text) { return d }
    let df2 = DateFormatter()
    df2.locale = Locale(identifier: "en_US_POSIX")
    df2.timeZone = TimeZone.current
    df2.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
    return df2.date(from: text)
}

private func timeRangeStable(start: String, end: String) -> String {
    guard let s = parseIsoStable(start), let e = parseIsoStable(end) else { return "--" }
    let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"
    let f2 = DateFormatter(); f2.dateFormat = "HH:mm"
    return "\(f.string(from: s)) - \(f2.string(from: e))"
}

private struct ChangesPreview: View {
    let changes: ModifyParserResult.Changes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.orange)
                Text("将进行以下修改")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
            }
            if let t = changes.title, !t.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "textformat")
                    Text("标题 → \(t)").font(.caption)
                }
            }
            if let s = changes.startTime, let e = changes.endTime {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text("时间 → \(formatRange(start: s, end: e))").font(.caption)
                }
            }
            if let loc = changes.location, !loc.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin")
                    Text("地点 → \(loc)").font(.caption)
                }
            }
            if let mm = changes.meeting_mode, !mm.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "video")
                    Text("会议形式 → \(mm == "online" ? "线上" : "线下")").font(.caption)
                }
            }
            if let add = changes.add_names, !add.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                    Text("加人：\(add.joined(separator: ", "))").font(.caption)
                }
            }
            if let rm = changes.remove_names, !rm.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.minus")
                    Text("去人：\(rm.joined(separator: ", "))").font(.caption)
                }
            }
            if let notes = changes.notes, !notes.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "note.text")
                    Text("备注 → \(notes)").font(.caption)
                }
            }
        }
    }

    private func formatRange(start: String, end: String) -> String {
        let iso = ISO8601DateFormatter()
        if let s = iso.date(from: start), let e = iso.date(from: end) {
            let f1 = DateFormatter(); f1.dateFormat = "M月d日 HH:mm"
            let f2 = DateFormatter(); f2.dateFormat = "HH:mm"
            return "\(f1.string(from: s)) - \(f2.string(from: e))"
        }
        return "\(start) → \(end)"
    }
}

// MARK: - 导出聊天记录
extension VoiceChatView {
    /// 导出聊天记录为文本文件
    private func exportChatHistory() {
        let chatText = formatChatHistoryForExport()
        
        // 生成文件名（带时间戳）
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "Follo_聊天记录_\(timestamp).txt"
        
        // 保存到临时目录
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try chatText.write(to: fileURL, atomically: true, encoding: .utf8)
            exportFileURL = fileURL
            showExportSheet = true
        } catch {
            print("❌ 导出聊天记录失败: \(error)")
        }
    }
    
    /// 格式化聊天记录为可读文本
    private func formatChatHistoryForExport() -> String {
        var lines: [String] = []
        
        // 标题
        lines.append("═══════════════════════════════════════════")
        lines.append("        Follo AI 聊天记录导出")
        lines.append("═══════════════════════════════════════════")
        lines.append("")
        
        // 导出时间
        let exportDateFormatter = DateFormatter()
        exportDateFormatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        lines.append("导出时间: \(exportDateFormatter.string(from: Date()))")
        lines.append("消息数量: \(voiceChatService.messages.count) 条")
        lines.append("")
        lines.append("───────────────────────────────────────────")
        lines.append("")
        
        // 消息内容
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "M月d日 HH:mm"
        
        for message in voiceChatService.messages {
            let role = message.isUser ? "👤 用户" : "🤖 Follo AI"
            let time = timeFormatter.string(from: message.timestamp)
            let typeIcon = message.messageType == .voice ? " 🎤" : ""
            
            lines.append("[\(time)] \(role)\(typeIcon)")
            lines.append(message.content)
            
            // 如果有 Agent A 标签
            if let tags = message.agentATags, !tags.isEmpty {
                let tagStr = tags.map { "\($0.label)" }.joined(separator: ", ")
                lines.append("  📌 情境标签: \(tagStr)")
            }
            
            // 如果有 Agent B 通知
            if let notifications = message.agentBNotifications, !notifications.isEmpty {
                lines.append("  🔔 智能建议:")
                for notif in notifications {
                    lines.append("    • \(notif.title)")
                    if let body = notif.body, !body.isEmpty {
                        lines.append("      \(body)")
                    }
                }
            }
            
            // 如果有操作结果
            if let ops = message.appliedOps, !ops.isEmpty {
                lines.append("  📅 操作结果:")
                for op in ops {
                    let status = op.success ? "✅" : "❌"
                    lines.append("    \(status) \(op.operation): \(op.title ?? "(无标题)")")
                }
            }
            
            lines.append("")
        }
        
        // 结尾
        lines.append("───────────────────────────────────────────")
        lines.append("        — Follo AI 智能日程助手 —")
        lines.append("═══════════════════════════════════════════")
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - ShareSheet（系统分享）
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 动作：创建事件 / 打开日视图
extension VoiceChatView {
    private func createEvent(from s: AIScheduleSuggestion) {
        guard let startStr = s.startTime, let endStr = s.endTime,
              let start = ISO8601DateFormatter().date(from: startStr),
              let end = ISO8601DateFormatter().date(from: endStr) else { return }
        let ev = calendarProvider.makeDraftEvent(on: start)
        ev.title = s.title ?? ""
        ev.startDate = start
        ev.endDate = end
        ev.location = (s.location?.isEmpty == false) ? s.location : nil
        ev.notes = s.ai_metadata?.reasoning
        do {
            try calendarProvider.save(event: ev)
            // 更新最近一条 AI 消息，写入 createdEventIdentifier
            if let idx = voiceChatService.messages.lastIndex(where: { !$0.isUser }) {
                voiceChatService.messages[idx].createdEventIdentifier = ev.eventIdentifier
            }
            // 强制刷新并导航到日视图指定事件
            calendarProvider.refreshDays(from: start, to: end)
            highlightEventId = ev.eventIdentifier
            openDay(for: start)
        } catch {
            // 简单忽略错误，生产中应提示
        }
    }

    private func openDay(for date: Date) {
    calendarProvider.select(date: date)
    targetDayDate = date
    highlightEventId = nil
        navigateToDay = true
    }
}

// MARK: - 直连模式 UI 组件

/// Agent A 标签展示
private struct AgentATagsView: View {
    let tags: [ContextTagWrapper]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "tag.fill")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text("情境标签")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
            }
            
            FlowLayout(spacing: 6) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag.label)
                            .font(.caption2)
                        if let conf = tag.confidence {
                            Text("\(Int(conf * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(10)
    }
}

/// Agent B 通知展示
private struct AgentBNotificationsView: View {
    let notifications: [NotificationItemWrapper]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("智能建议")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
            }
            
            ForEach(notifications) { notif in
                HStack(alignment: .top, spacing: 8) {
                    Text(severityIcon(notif.severity))
                        .font(.body)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notif.title)
                            .font(.subheadline.weight(.medium))
                        
                        if let body = notif.body, !body.isEmpty {
                            Text(body)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(severityColor(notif.severity).opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(10)
    }
    
    private func severityIcon(_ severity: String?) -> String {
        switch severity?.lowercased() {
        case "high", "urgent": return "🔴"
        case "medium", "normal": return "🟡"
        case "low", "info": return "🟢"
        default: return "ℹ️"
        }
    }
    
    private func severityColor(_ severity: String?) -> Color {
        switch severity?.lowercased() {
        case "high", "urgent": return .red
        case "medium", "normal": return .orange
        case "low", "info": return .green
        default: return .blue
        }
    }
}

/// 直连模式调试信息（可折叠）
private struct DirectModeDebugView: View {
    let debugInfo: String
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "ladybug.fill")
                        .foregroundColor(.gray)
                        .font(.caption2)
                    Text("调试信息")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.gray)
                        .font(.caption2)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                ScrollView {
                    Text(debugInfo)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
            }
        }
        .padding(8)
        .background(Color(.systemGray5).opacity(0.3))
        .cornerRadius(8)
    }
}

/// 流式布局（用于标签展示）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + rowHeight
        }
    }
}

#Preview {
    VoiceChatView()
}
