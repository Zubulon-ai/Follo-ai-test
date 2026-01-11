//
//  VoiceChatService.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/8/13.
//

import Foundation
import AVFoundation
import Speech
import SwiftUI
import EventKit

// 修改/删除前的候选确认上下文（Modify Parser -> 本地定位），用于消息流与 UI 展示
struct ModifyConfirmContext: Codable {
    let action: String // DELETE | UPDATE
    let candidates: [LocatedEventCandidate]
    let changes: ModifyParserResult.Changes?
}

// 执行操作后的结果摘要，用于 UI 展示与导航
struct AppliedOperationSummary: Codable, Identifiable {
    let id = UUID()
    let operation: String
    let targetEventId: String?
    let title: String?
    let startTime: String?
    let endTime: String?
    
    let success: Bool
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case operation, targetEventId, title, startTime, endTime, success, message
    }
}

// MARK: - 语音消息数据模型
struct VoiceMessage: Identifiable, Codable {
    let id: UUID
    let content: String // 消息内容（对于语音消息是转录文本）
    let isUser: Bool // true为用户消息，false为AI回复
    let timestamp: Date
    let messageType: MessageType
    let audioFileURL: URL? // 语音文件路径（仅语音消息使用）
    let audioDuration: TimeInterval? // 语音时长（仅语音消息使用）
    // AI 返回的日程建议（若有）
    var scheduleSuggestion: AIScheduleSuggestion?
    // 自动创建后的事件标识
    var createdEventIdentifier: String?
    // 批量操作执行结果（用于 UI 展示）
    var appliedOps: [AppliedOperationSummary]? = nil
    // 会议助手返回的解析结果（仅会议模式）
    var meetingResult: MeetingAssistantResult? = nil
    // 修改/删除前的候选确认上下文（Modify Parser -> 本地定位）
    var modifyConfirm: ModifyConfirmContext? = nil
    // 直连模式：Agent A 的情境标签
    var agentATags: [ContextTagWrapper]? = nil
    // 直连模式：Agent B 的通知建议
    var agentBNotifications: [NotificationItemWrapper]? = nil
    // 直连模式：调试信息
    var directModeDebugInfo: String? = nil
    
    enum MessageType: String, Codable {
        case text = "text"
        case voice = "voice"
    }
    
    init(content: String, isUser: Bool, timestamp: Date, messageType: MessageType, audioFileURL: URL? = nil, audioDuration: TimeInterval? = nil, scheduleSuggestion: AIScheduleSuggestion? = nil, createdEventIdentifier: String? = nil) {
        self.id = UUID()
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.messageType = messageType
        self.audioFileURL = audioFileURL
        self.audioDuration = audioDuration
        self.scheduleSuggestion = scheduleSuggestion
        self.createdEventIdentifier = createdEventIdentifier
    }
}

// MARK: - 直连模式数据包装（Codable 兼容）
struct ContextTagWrapper: Codable, Identifiable {
    let key: String
    let label: String
    let confidence: Double?
    var id: String { key }
    
    init(from tag: ContextTag) {
        self.key = tag.key
        self.label = tag.label
        self.confidence = tag.confidence
    }
}

struct NotificationItemWrapper: Codable, Identifiable {
    let title: String
    let body: String?
    let severity: String?
    var id: String { title + (body ?? "") }
    
    init(from item: NotificationItem) {
        self.title = item.title
        self.body = item.body
        self.severity = item.severity
    }
}

// MARK: - AI日程建议模型
struct AIScheduleSuggestion: Codable {
    struct AIMetadata: Codable {
        let confidence_score: Double?
        let reasoning: String?
        let response: String?
    }
    let title: String?
    let startTime: String?
    let endTime: String?
    let duration: Int?
    let location: String?
    let tags: [String]?
    let status: String?
    let ai_metadata: AIMetadata?
}

// MARK: - 会议助手返回模型
struct MeetingAssistantResult: Codable {
    struct MeetingDetails: Codable {
        let title: String?
        let duration: Int?
        let attendees: [String]?
    }
    struct ProposedOption: Codable, Identifiable {
        let option_id: Int?
        let startTime: String?
        let endTime: String?
        let reasoning: String?
        var id: Int { option_id ?? Int.random(in: 1...9999) }
    }
    let meeting_details: MeetingDetails?
    let proposed_options: [ProposedOption]?
    let response: String?
}

// MARK: - 语音聊天服务
class VoiceChatService: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var messages: [VoiceMessage] = []
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var playingMessageId: UUID?
    @Published var currentRecordingLevel: Float = 0.0
    @Published var currentDecibelLevel: Int = 0
    @Published var isTranscribing = false
    @Published var isAIResponding = false
    // 友好提示弹窗状态（用于短语音/未识别等场景）
    @Published var friendlyAlertState: FriendlyAlertState? = nil
    
    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var openAIService = OpenAIService()
    private let eventStore = GlobalEventStore.shared.store
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()
    // 备用：无毫秒的 ISO8601 解析器
    private let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()
    
    // 录音文件管理
    private let documentsDirectory: URL
    private var currentRecordingURL: URL?
    
    // 音频录制监听定时器
    private var levelTimer: Timer?
    // 供外部注入最近状态数据（与主界面一致的采集信息），未注入则回退使用最近对话文本
    var recentStatusDataProvider: (() -> [String])?
    // 供外部注入：应用内日历事件（用于 Calendar JSON 构造，优先于系统日历）
    var appCalendarEventsProvider: (() -> [EKEvent])?
    // 供外部注入：用户基本信息（用于 preference）
    var userInfoProvider: (() -> UserInfo?)?
    // 协作助手上下文提供者（当进入会议模式时注入）
    struct MeetingContext {
        let recipientName: String
        let recipientPreferencesJSON: String
        let recipientCalendarJSON: String
        let requesterName: String // 恒宇
    }
    var meetingContextProvider: (() -> MeetingContext)?
    enum AIMode { case normal, meeting, quickCreate }
    var aiMode: AIMode = .normal
    // 最近一次修改任务的候选缓存（按 utterance 隔离）
    private var modifyCandidatesByUtterance: [String: [LocatedEventCandidate]] = [:]
    private var lastModifyUtterance: String? = nil
    // 幂等：记录已删除过的 key（eventId|occurrenceStartISO），避免重复执行
    private var deletedKeys: Set<String> = []
    // 友好提示模型
    struct FriendlyAlertState: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    override init() {
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        super.init()
        setupSpeechRecognizer()
        setupAudioSession()
    }
    
    deinit {
        stopVoiceRecording()
        stopPlaying()
        levelTimer?.invalidate()
    }
    
    // MARK: - Setup Methods
    private func setupSpeechRecognizer() {
        // 检查设备是否支持语音识别
        guard SFSpeechRecognizer.authorizationStatus() != .restricted else {
            print("❌ 设备不支持语音识别")
            return
        }
        
        // 设置语音识别器，优先使用中文，失败则使用默认语言
        if let chineseRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
           chineseRecognizer.isAvailable {
            speechRecognizer = chineseRecognizer
            print("✅ 使用中文语音识别器")
        } else if let defaultRecognizer = SFSpeechRecognizer() {
            speechRecognizer = defaultRecognizer
            print("⚠️ 中文语音识别不可用，使用默认语音识别器")
        } else {
            print("❌ 无法创建语音识别器")
            return
        }
        
        // 请求语音识别权限
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    print("✅ 语音识别权限已授予")
                case .denied:
                    print("❌ 语音识别权限被拒绝")
                case .restricted:
                    print("❌ 语音识别权限受限制")
                case .notDetermined:
                    print("⚠️ 语音识别权限未确定")
                @unknown default:
                    print("❓ 未知语音识别权限状态")
                }
            }
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            print("音频会话设置失败: \(error)")
        }
    }
    
    // MARK: - Voice Recording Methods
    func startVoiceRecording() {
        guard !isRecording else { return }
        
        // 请求麦克风权限
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginRecording()
                    } else {
                        print("麦克风权限被拒绝")
                    }
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginRecording()
                    } else {
                        print("麦克风权限被拒绝")
                    }
                }
            }
        }
    }
    
    private func beginRecording() {
        // 生成录音文件URL
        let fileName = "voice_\(Date().timeIntervalSince1970).m4a"
        currentRecordingURL = documentsDirectory.appendingPathComponent(fileName)
        
        guard let recordingURL = currentRecordingURL else { return }
        
        // 配置录音设置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            isRecording = true
            
            // 开始监听录音音量
            startLevelMonitoring()
            
            print("开始录音: \(recordingURL.lastPathComponent)")
        } catch {
            print("录音失败: \(error)")
        }
    }
    
    func stopVoiceRecording() {
        guard isRecording else { return }
        
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        
        // 停止音量监听
        stopLevelMonitoring()
        
        // 开始语音转文字
        if let recordingURL = currentRecordingURL {
            // 若语音过短，则直接提示并不进入识别
            let duration = getAudioDuration(from: recordingURL)
            if duration < 0.8 {
                presentFriendlyAlert(title: "说话太短", message: "请按住说话更久一些，再试一次。")
                return
            }
            transcribeAudio(from: recordingURL)
        }
    }

    // 解析 Modify Resolver 返回
    struct ModifyResolverResult: Codable {
        struct Changes: Codable {
            let startTime: String?
            let endTime: String?
            let location: String?
            let meeting_mode: String?
            let add_names: [String]?
            let remove_names: [String]?
            let title: String?
            let notes: String?
        }
        let choice: Int?
        let action: String
        let changes: Changes?
        let missing: [String]?
        let reply: String?
    }

    private func parseModifyResolver(from text: String) -> ModifyResolverResult? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        if let data = jsonStr.data(using: .utf8) {
            let dec = JSONDecoder()
            if let val = try? dec.decode(ModifyResolverResult.self, from: data) { return val }
        }
        let cleaned = jsonStr.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8) {
            let dec = JSONDecoder()
            return try? dec.decode(ModifyResolverResult.self, from: data2)
        }
        return nil
    }
    private func normalizedLevel(from power: Float) -> Float {
        let normalized = (power + 160) / 160
        return max(0, min(normalized, 1))
    }

    // 将麦克风的 dBFS 值映射到 0-110 dB 的主观响度刻度
    private func displayDecibels(from power: Float) -> Int {
        let compensatedPower = power + 160 - 50

        switch compensatedPower {
        case ..<0:
            return 0
        case ..<40:
            return Int(compensatedPower * 0.875)
        case ..<100:
            return Int(compensatedPower - 15)
        case ..<110:
            return Int(compensatedPower * 2.5 - 165)
        default:
            return 110
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.audioRecorder?.updateMeters()

            guard let power = self.audioRecorder?.averagePower(forChannel: 0) else {
                self.currentRecordingLevel = 0
                self.currentDecibelLevel = 0
                return
            }

            let clampedPower = max(power, -160)
            let normalizedLevel = self.normalizedLevel(from: clampedPower)
            let displayDb = self.displayDecibels(from: clampedPower)

            self.currentRecordingLevel = normalizedLevel
            self.currentDecibelLevel = displayDb
        }
    }
    
    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        currentRecordingLevel = 0.0
        currentDecibelLevel = 0
    }
    
    // MARK: - Speech Recognition Methods
    private func transcribeAudio(from url: URL) {
        print("🎙️ 开始语音转录，文件路径: \(url.path)")
        
        // 检查语音识别器状态
        guard let speechRecognizer = speechRecognizer else {
            print("❌ 语音识别器未初始化")
            addErrorMessage("语音识别器未初始化")
            return
        }
        
        guard speechRecognizer.isAvailable else {
            print("❌ 语音识别当前不可用")
            addErrorMessage("语音识别当前不可用，请稍后再试")
            return
        }
        
        // 检查权限状态
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            print("❌ 语音识别权限未授权，当前状态: \(SFSpeechRecognizer.authorizationStatus())")
            addErrorMessage("请在设置中开启语音识别权限")
            return
        }
        
        // 检查音频文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ 音频文件不存在: \(url.path)")
            addErrorMessage("音频文件不存在")
            return
        }
        
        isTranscribing = true
        
        // 取消之前的识别任务
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false // 允许网络识别以提高准确性
        
        print("🔄 发起语音识别请求...")
        
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.isTranscribing = false
                
                if let error = error {
                    let nsError = error as NSError
                    print("❌ 语音识别错误:")
                    print("   错误域: \(nsError.domain)")
                    print("   错误代码: \(nsError.code)")
                    print("   错误描述: \(nsError.localizedDescription)")
                    
                    // 若音频时长过短或常见“未识别”情形，展示友好提示
                    let audioDuration = self?.getAudioDuration(from: url) ?? 0
                    if audioDuration < 1.0 {
                        self?.presentFriendlyAlert(title: "说话太短", message: "未能听清楚，请再试一次。")
                        return
                    }
                    // 错误代码 1110：通常表示未检测到有效语音
                    if nsError.code == 1110 {
                        self?.presentFriendlyAlert(title: "未检测到说话内容", message: "没有检测到您的说话内容，请再试一次。")
                        return
                    }
                    // 其他错误保留原有错误到聊天
                    var errorMessage = "语音识别失败"
                    if nsError.domain == "kAFAssistantErrorDomain" {
                        switch nsError.code {
                        case 1101:
                            errorMessage = "语音识别服务暂时不可用，请检查网络连接"
                        case 203:
                            errorMessage = "语音识别请求被拒绝"
                        default:
                            errorMessage = "语音识别服务错误 (代码: \(nsError.code))"
                        }
                    }
                    self?.addErrorMessage(errorMessage)
                    return
                }
                
                if let result = result, result.isFinal {
                    let transcribedText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    print("✅ 语音转文字成功: \(transcribedText)")
                    
                    guard !transcribedText.isEmpty else {
                        print("⚠️ 语音转录结果为空")
                        self?.presentFriendlyAlert(title: "未听清楚", message: "未能识别到您的语音内容，请再试一次。")
                        return
                    }
                    
                    // 计算音频时长
                    let duration = self?.getAudioDuration(from: url) ?? 0
                    
                    // 创建语音消息
                    let voiceMessage = VoiceMessage(
                        content: transcribedText,
                        isUser: true,
                        timestamp: Date(),
                        messageType: .voice,
                        audioFileURL: url,
                        audioDuration: duration
                    )
                    
                    self?.messages.append(voiceMessage)
                    
                    // 发送给AI处理
                    self?.sendToAI(message: transcribedText)
                }
            }
        }
    }
    
    private func getAudioDuration(from url: URL) -> TimeInterval {
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            return audioPlayer.duration
        } catch {
            print("获取音频时长失败: \(error)")
            return 0
        }
    }
    
    // MARK: - Audio Playback Methods
    func playVoiceMessage(_ message: VoiceMessage) {
        guard let audioURL = message.audioFileURL,
              !isPlaying else { return }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            isPlaying = true
            playingMessageId = message.id
            
            print("播放语音: \(audioURL.lastPathComponent)")
        } catch {
            print("播放失败: \(error)")
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingMessageId = nil
    }
    
    // MARK: - AI Integration Methods
    func sendToAI(message: String) {
        isAIResponding = true
        
        Task {
            // 每次发起新的 AI 交互，清空本轮的修改候选缓存，防止跨轮污染
            self.modifyCandidatesByUtterance.removeAll()
            self.lastModifyUtterance = nil
            
            // ==========================================
            // 直连模式分支：使用 A/B 智能体串联
            // ==========================================
            if AppConfig.directDashScopeEnabled {
                await sendToAIDirect(message: message)
                return
            }
            
            // ==========================================
            // 后端模式分支：原有逻辑
            // ==========================================
            do {
                var raw: String
                var hasPartial = false
                if aiMode == .meeting, let ctx = meetingContextProvider?() {
                    // 会议模式：调用 Meeting Assistant 应用
                    var meetingPrompt = buildContextPrompt(currentMessage: message)
                    raw = try await openAIService.callMeetingAssistant(
                        promptText: meetingPrompt,
                        recipientName: ctx.recipientName,
                        recipientPrefsJSON: ctx.recipientPreferencesJSON,
                        recipientCalendarJSON: ctx.recipientCalendarJSON,
                        requesterName: ctx.requesterName,
                        requesterUserInfo: self.userInfoProvider?(),
                        requesterAppCalendarEvents: self.appCalendarEventsProvider?()
                    )
                    // 如果无法解析会议 JSON，进行一次兜底重试
                    if self.parseMeetingResult(from: raw) == nil {
                        meetingPrompt = enforceMeetingJSONPrompt(basePrompt: meetingPrompt)
                        raw = try await openAIService.callMeetingAssistant(
                            promptText: meetingPrompt,
                            recipientName: ctx.recipientName,
                            recipientPrefsJSON: ctx.recipientPreferencesJSON,
                            recipientCalendarJSON: ctx.recipientCalendarJSON,
                            requesterName: ctx.requesterName,
                            requesterUserInfo: self.userInfoProvider?(),
                            requesterAppCalendarEvents: self.appCalendarEventsProvider?()
                        )
                    }
                } else if aiMode == .quickCreate {
                    let prompt = buildContextPrompt(currentMessage: message)
                    raw = try await openAIService.callQuickCreateApp(
                        prompt: prompt,
                        userInfo: self.userInfoProvider?(),
                        appCalendarEvents: self.appCalendarEventsProvider?(),
                        recentStatusData: buildRecentStatusForSensor()
                    )
                    // 若 operations JSON 解析失败，进行一次兜底重试
                    if self.parseAIResult(from: raw) == nil {
                        let strict = enforceOperationsJSONPrompt(basePrompt: prompt)
                        raw = try await openAIService.callQuickCreateApp(
                            prompt: strict,
                            userInfo: self.userInfoProvider?(),
                            appCalendarEvents: self.appCalendarEventsProvider?(),
                            recentStatusData: buildRecentStatusForSensor()
                        )
                    }
                } else {
                    // 普通模式：原逻辑 + 即时/阶段反馈
                    let prompt = buildContextPrompt(currentMessage: message)

                    // 移除“分析中”气泡，不再显示

                    raw = try await openAIService.callDashScopeApp(
                        prompt: prompt,
                        userInfo: self.userInfoProvider?(),
                        appCalendarEvents: self.appCalendarEventsProvider?(),
                        recentStatusData: buildRecentStatusForSensor(),
                        onAnalysis: { tasks in
							// 分析完成后，追加“已理解需求”系统气泡（按任务类型定制文案）
							let summary: String
							if tasks.isEmpty {
								summary = "明白您的需求！正在为您处理请求。"
							} else {
								let createUtts = tasks.filter { $0.operation.uppercased() == "CREATE" }.map { $0.utterance }
								let modifyUtts = tasks.filter { $0.operation.uppercased() == "MODIFY" }.map { $0.utterance }
								let otherUtts = tasks.filter { $0.operation.uppercased() == "OTHER" }.map { $0.utterance }

								var segments: [String] = []
								if !createUtts.isEmpty {
									let joined = createUtts.prefix(3).joined(separator: "；")
									segments.append("创建日程：\(joined)")
								}
								if !modifyUtts.isEmpty {
									let joined = modifyUtts.prefix(3).joined(separator: "；")
									segments.append("修改日程：\(joined)")
								}
								if !otherUtts.isEmpty {
									let joined = otherUtts.prefix(3).joined(separator: "；")
									segments.append("解决：\(joined)")
								}
								summary = "明白您的需求！正在为您" + segments.joined(separator: "；")
							}
                            DispatchQueue.main.async {
                                let understood = VoiceMessage(
                                    content: summary,
                                    isUser: false,
                                    timestamp: Date(),
                                    messageType: .text,
                                    audioFileURL: nil,
                                    audioDuration: nil,
                                    scheduleSuggestion: nil,
                                    createdEventIdentifier: nil
                                )
                                self.messages.append(understood)
                            }
                        },
                        onPartial: { task, result in
                            hasPartial = true
                            // 更新当前子任务的utterance，用于后续choice映射
                            self.lastModifyUtterance = task.utterance
							// OTHER 应用：仅解析并展示 response 字段，忽略其他内容
							if task.operation.uppercased() == "OTHER" {
								if let parsed = self.parseAIResult(from: result) {
									let resp = parsed.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
									DispatchQueue.main.async {
										let ai = VoiceMessage(content: resp.isEmpty ? "" : resp, isUser: false, timestamp: Date(), messageType: .text)
										self.messages.append(ai)
									}
									return
								} else {
									// 若非结构化返回，直接展示原始文本
									DispatchQueue.main.async {
										let ai = VoiceMessage(content: result, isUser: false, timestamp: Date(), messageType: .text)
										self.messages.append(ai)
									}
									return
								}
							}
                            // 逐条解析：优先尝试 ModifyResolver；否则尝试通用 operations+response；会议模式不在此分支
                            if let resolver = self.parseModifyResolver(from: result) {
                                // 确保有候选映射：若为空则基于原话做一次定位
                                if (self.lastModifyUtterance == nil) || (self.modifyCandidatesByUtterance[self.lastModifyUtterance!] == nil) {
                                    let locator = EventLocator(store: self.eventStore, embeddingProvider: self.openAIService)
                                    let cands: [LocatedEventCandidate] = self.awaitResult {
                                        await locator.locateFromUtterance(task.utterance, maxK: 3, debug: true)
                                    } ?? []
                                    self.modifyCandidatesByUtterance[task.utterance] = cands
                                    self.lastModifyUtterance = task.utterance
                                    print("[Modify] seeded candidates for utterance=\(task.utterance) (count=\(cands.count))")
                                    for (i, c) in cands.enumerated() { print("  [#\(i+1)] \(c.title) [\(c.start) ~ \(c.end)] id=\(c.id)") }
                                }

                                let reply = resolver.reply ?? ""
                                let upperAction = resolver.action.uppercased()
                                let cached = self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""] ?? []
                                if let choice = resolver.choice, choice >= 1, choice <= 3, choice-1 < cached.count {
                                    let picked = cached[choice-1]
                                    print("[Modify] choice=\(choice), picked=\(picked.title) [\(picked.start) ~ \(picked.end)]")
                                    if upperAction == "DELETE" {
                                        // 删除走确认卡片
                                        DispatchQueue.main.async {
                                            var msg = VoiceMessage(content: "请确认删除以下日程：", isUser: false, timestamp: Date(), messageType: .text)
                                            msg.modifyConfirm = ModifyConfirmContext(action: "DELETE", candidates: [picked], changes: nil)
                                            self.messages.append(msg)
                                        }
                                        return
                                    } else if upperAction == "UPDATE" {
                                        // 直接执行更新，并展示回复
                                        var payload: [String: AnyCodable] = [:]
                                        if let ch = resolver.changes {
                                            if let t = ch.title { payload["title"] = AnyCodable(t) }
                                            if let s = ch.startTime { payload["startTime"] = AnyCodable(s) }
                                            if let e = ch.endTime { payload["endTime"] = AnyCodable(e) }
                                            if let loc = ch.location { payload["location"] = AnyCodable(loc) }
                                            if let notes = ch.notes { payload["notes"] = AnyCodable(notes) }
                                        }
                                        let r = self.updateEvent(eventId: picked.id, with: payload)
                                        DispatchQueue.main.async {
                                            var ai = VoiceMessage(content: reply, isUser: false, timestamp: Date(), messageType: .text)
                                            ai.appliedOps = [r]
                                            self.messages.append(ai)
                                            // 不自动跳转，交由结果卡片点击触发
                                        }
                                        return
                                    }
                                }
                                // 未选定候选或无法匹配，展示回复并弹确认卡（依据 action）
                                if upperAction == "DELETE" || upperAction == "UPDATE" {
                                    let candidates = self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""] ?? []
                                    let tip = upperAction == "DELETE" ? "你是需要删除下面这个/这些日程吗？" : (self.formatChangesText(self.toParserChanges(resolver.changes)))
                                    DispatchQueue.main.async {
                                        // 先展示模型的礼貌回复
                                        let replyMsg = VoiceMessage(content: reply, isUser: false, timestamp: Date(), messageType: .text)
                                        self.messages.append(replyMsg)
                                        // 再展示确认卡
                                        var card = VoiceMessage(content: tip, isUser: false, timestamp: Date(), messageType: .text)
                                        card.modifyConfirm = ModifyConfirmContext(action: upperAction, candidates: candidates, changes: self.toParserChanges(resolver.changes))
                                        self.messages.append(card)
                                    }
                                    return
                                }
                                // 其他情况：仅展示回复
                                DispatchQueue.main.async {
                                    let ai = VoiceMessage(content: reply, isUser: false, timestamp: Date(), messageType: .text)
                                    self.messages.append(ai)
                                }
                                return
                            }
                            // 通用 operations + response
                            if let parsed = self.parseAIResult(from: result) {
                                // 若包含 UPDATE/DELETE，则弹确认卡片，不直接执行
                                if let ops = parsed.operations, !ops.isEmpty {
                                    var handledSpecial = false
                                    for op in ops {
                                        let kind = op.operation.uppercased()
                                        if kind == "UPDATE" || kind == "DELETE" {
                                            handledSpecial = true
                                            // 构建候选：若目标ID存在，则仅该事件；否则基于原始话语语义召回
                                            var candidates: [LocatedEventCandidate] = []
                                            if let targetId = op.target_event_id, let ev = self.eventStore.event(withIdentifier: targetId) {
                                                if let s = ev.startDate, let e = ev.endDate {
                                                    candidates.append(LocatedEventCandidate(
                                                        id: targetId,
                                                        title: ev.title ?? "",
                                                        start: self.iso8601.string(from: s),
                                                        end: self.iso8601.string(from: e),
                                                        isAllDay: ev.isAllDay,
                                                        location: ev.location,
                                                        calendarTitle: ev.calendar.title,
                                                        attendees: nil,
                                                        score: 1.0
                                                    ))
                                                }
                                            } else {
                                                if let cached = self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""], !cached.isEmpty {
                                                    candidates = cached
                                                } else {
                                                    let locator = EventLocator(store: self.eventStore, embeddingProvider: self.openAIService)
                                                    let cands: [LocatedEventCandidate] = self.awaitResult {
                                                        await locator.locateFromUtterance(task.utterance, maxK: 3, debug: true)
                                                    } ?? []
                                                    self.modifyCandidatesByUtterance[task.utterance] = cands
                                                    self.lastModifyUtterance = task.utterance
                                                    candidates = cands
                                                }
                                            }
                                            let usedCache = (self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""]?.isEmpty == false)
                                            print("[Modify] confirm card candidates (count=\(candidates.count)) from \(usedCache ? "cache" : "locateFromUtterance")")
                                            for (i, c) in candidates.enumerated() { print("  [#\(i+1)] \(c.title) [\(c.start) ~ \(c.end)] id=\(c.id)") }
                                            // UPDATE 需要给出修改部分与内容
                                            var changesOut: ModifyParserResult.Changes? = nil
                                            if kind == "UPDATE" {
                                                changesOut = self.buildChangesFromPayload(op.payload)
                                            }
                                            let tip: String = (kind == "DELETE") ? "请确认删除以下日程：" : self.formatChangesText(changesOut)
                                            DispatchQueue.main.async {
                                                var msg = VoiceMessage(content: tip, isUser: false, timestamp: Date(), messageType: .text)
                                                msg.modifyConfirm = ModifyConfirmContext(action: kind, candidates: candidates, changes: changesOut)
                                                self.messages.append(msg)
                                            }
                                        }
                                    }
                                    if handledSpecial { return }
                                }
                                // 否则按原逻辑执行（常用于 CREATE）
                                let response = parsed.response?.trimmingCharacters(in: .whitespacesAndNewlines)
                                let display = (response?.isEmpty == false) ? response! : result
                                let applied = (parsed.operations ?? []).isEmpty ? [] : self.applyOperations(parsed.operations ?? [])
                                DispatchQueue.main.async {
                                    var ai = VoiceMessage(content: display, isUser: false, timestamp: Date(), messageType: .text)
                                    ai.appliedOps = applied
                                    self.messages.append(ai)
                                }
                                return
                            }
                            // 若不是结构化 JSON，作为普通文本片段展示
                            DispatchQueue.main.async {
                                let ai = VoiceMessage(content: result, isUser: false, timestamp: Date(), messageType: .text)
                                self.messages.append(ai)
                            }
                        },
                        onCandidates: { utterance, cands in
                            // 缓存与模型一致的候选，以便后续 choice 直接映射
                            self.modifyCandidatesByUtterance[utterance] = cands
                            self.lastModifyUtterance = utterance
                            print("[Modify] cached candidates from OpenAIService for utterance=\(utterance) (count=\(cands.count))")
                        }
                    )
                }
    // 若已收到任意分片结果，则跳过汇总展示，直接结束加载状态
    if hasPartial {
        DispatchQueue.main.async {
            self.isAIResponding = false
        }
        return
    }
    // 新流程：若未收到任何 partial，则对最终汇总文本再做一次解析；否则跳过避免重复
    if !hasPartial, let resolver = self.parseModifyResolver(from: raw) {
        // 确保有最近一次候选映射；若为空则基于原始话语即时定位一次
        if (resolver.choice ?? 0) >= 1 && (resolver.choice ?? 0) <= 3,
           (self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""] ?? []).isEmpty {
            let locator = EventLocator(store: eventStore, embeddingProvider: openAIService)
            let cands: [LocatedEventCandidate] = awaitResult {
                await locator.locateFromUtterance(message, maxK: 3, debug: true)
            } ?? []
            self.modifyCandidatesByUtterance[message] = cands
            self.lastModifyUtterance = message
        }
        DispatchQueue.main.async {
            let reply = resolver.reply ?? ""
            var ai = VoiceMessage(content: reply, isUser: false, timestamp: Date(), messageType: .text)
            // 若命中候选则直接应用并回显
            let cached = self.modifyCandidatesByUtterance[self.lastModifyUtterance ?? ""] ?? []
            if let choice = resolver.choice, choice >= 1, choice <= 3, choice-1 < cached.count {
                let picked = cached[choice-1]
                if resolver.action.uppercased() == "DELETE" {
                    let occ = self.parseFlexibleDate(picked.start)
                    let r = self.deleteEvent(eventId: picked.id, occurrenceStart: occ)
                    ai.appliedOps = [r]
                } else if resolver.action.uppercased() == "UPDATE" {
                    var payload: [String: AnyCodable] = [:]
                    if let ch = resolver.changes {
                        if let t = ch.title { payload["title"] = AnyCodable(t) }
                        if let s = ch.startTime { payload["startTime"] = AnyCodable(s) }
                        if let e = ch.endTime { payload["endTime"] = AnyCodable(e) }
                        if let loc = ch.location { payload["location"] = AnyCodable(loc) }
                        if let notes = ch.notes { payload["notes"] = AnyCodable(notes) }
                    }
                    let r = self.updateEvent(eventId: picked.id, with: payload)
                    ai.appliedOps = [r]
                }
            }
            self.messages.append(ai)
            self.isAIResponding = false
        }
        return
    }

    // 解析AI返回的JSON（新格式：operations+response），仅在未有partial时执行
    let parsed = hasPartial ? nil : self.parseAIResult(from: raw)
    let response = parsed?.response?.trimmingCharacters(in: .whitespacesAndNewlines)
    let display = (response?.isEmpty == false) ? response! : raw
    let ops = parsed?.operations ?? []
    let applied = ops.isEmpty ? [] : self.applyOperations(ops)
    
    // 在进入main queue之前处理会议结果，避免并发访问
    let meetingResult = self.aiMode == .meeting ? self.parseMeetingResult(from: raw) : nil
                
                DispatchQueue.main.async {
                    let aiMessage = VoiceMessage(
                        content: display,
                        isUser: false,
                        timestamp: Date(),
                        messageType: .text,
                        audioFileURL: nil,
                        audioDuration: nil,
                        scheduleSuggestion: nil,
                        createdEventIdentifier: nil
                    )
                    var enriched = aiMessage
                    enriched.appliedOps = applied
                    if self.aiMode == .meeting {
                        enriched.meetingResult = meetingResult
                    }
                    self.messages.append(enriched)
                    // 不再自动跳转；改为由 UI 卡片点击后再跳转
                    // TODO: 后续可在此处分发 parsed?.operations 进行批量日程操作
                    self.isAIResponding = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.addErrorMessage("AI回复失败: \(error.localizedDescription)")
                    self.isAIResponding = false
                }
            }
        }
    }

    // MARK: - 直连模式 AI 调用（A/B 智能体串联）
    
    private func sendToAIDirect(message: String) async {
        print("🔗 [VoiceChatService] 使用直连模式 (DashScope A/B)")
        
        // 检查 API Key
        guard AppConfig.dashScopeAPIKey != nil else {
            await MainActor.run {
                let errorMsg = VoiceMessage(
                    content: "⚠️ DashScope API Key 未配置\n\n请在 Info.plist 中设置 DashScopeAPIKey 后重试。",
                    isUser: false,
                    timestamp: Date(),
                    messageType: .text
                )
                self.messages.append(errorMsg)
                self.isAIResponding = false
            }
            return
        }
        
        // 调用 A/B 编排器
        let result = await ABOrchestrator.shared.run(userText: message)
        
        await MainActor.run {
            // 构建响应消息
            var aiMessage = VoiceMessage(
                content: result.displayText,
                isUser: false,
                timestamp: Date(),
                messageType: .text
            )
            
            // 附加直连模式的额外信息
            aiMessage.agentATags = result.tagsForDisplay.map { ContextTagWrapper(from: $0) }
            aiMessage.agentBNotifications = result.notificationsForDisplay.map { NotificationItemWrapper(from: $0) }
            aiMessage.directModeDebugInfo = result.debugLog
            
            self.messages.append(aiMessage)
            self.isAIResponding = false
            
            // 控制台输出调试信息
            print("📊 [直连模式] 调试信息:\n\(result.debugLog)")
        }
    }

    // MARK: - Modify 确认流

    private func tryBuildModifyConfirmation(from raw: String, originalUtterance: String) -> VoiceMessage? {
        let locator = EventLocator(store: eventStore, embeddingProvider: openAIService)
        guard let parsed = locator.decodeParserResult(from: raw) else { return nil }
        let action = parsed.action.uppercased()
        guard action == "DELETE" || action == "UPDATE" else { return nil }
        // 优先复用与模型对齐的候选（同一 utterance）
        let cands: [LocatedEventCandidate] = self.modifyCandidatesByUtterance[originalUtterance] ?? self.awaitResult {
            await locator.locateFromUtterance(originalUtterance, maxK: 3, debug: true)
        } ?? []
        self.modifyCandidatesByUtterance[originalUtterance] = cands
        self.lastModifyUtterance = originalUtterance
        let tip: String
        if cands.isEmpty {
            tip = action == "DELETE" ? "未定位到可删除的日程，请补充时间或标题线索。" : "未定位到可修改的日程，请补充时间或标题线索。"
        } else if cands.count == 1 {
            tip = action == "DELETE" ? "你是需要删除下面这个日程吗？" : "你是需要修改下面这个日程吗？"
        } else {
            tip = action == "DELETE" ? "定位到多个日程，你需要删除哪一个呢？" : "定位到多个日程，你需要修改哪一个呢？"
        }
        var msg = VoiceMessage(content: tip, isUser: false, timestamp: Date(), messageType: .text, audioFileURL: nil, audioDuration: nil, scheduleSuggestion: nil, createdEventIdentifier: nil)
        msg.modifyConfirm = ModifyConfirmContext(action: action, candidates: cands, changes: parsed.changes)
        return msg
    }

    private func awaitResult<T>(_ block: @escaping () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await block()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    func confirmModify(action: String, candidateId: String, occurrenceStart: Date?, changes: ModifyParserResult.Changes?) {
        let upper = action.uppercased()
        switch upper {
        case "DELETE":
            let key: String = {
                if let d = occurrenceStart { return candidateId + "|" + iso8601.string(from: d) }
                return candidateId + "|" + (iso8601.string(from: parseFlexibleDate(iso8601.string(from: Date())) ?? Date()))
            }()
            // 若已删除过，则直接返回成功提示，防止重复执行
            if deletedKeys.contains(key) {
                let r = AppliedOperationSummary(operation: "DELETE", targetEventId: candidateId, title: nil, startTime: occurrenceStart.map { iso8601.string(from: $0) }, endTime: nil, success: true, message: "已删除")
                DispatchQueue.main.async {
                    let ai = VoiceMessage(content: "已删除所选日程。", isUser: false, timestamp: Date(), messageType: .text)
                    var enriched = ai
                    enriched.appliedOps = [r]
                    self.messages.append(enriched)
                }
                return
            }
            let r = deleteEvent(eventId: candidateId, occurrenceStart: occurrenceStart)
            deletedKeys.insert(key)
            DispatchQueue.main.async {
                let ai = VoiceMessage(content: r.success ? "已删除所选日程。" : (r.message ?? "删除失败"), isUser: false, timestamp: Date(), messageType: .text)
                var enriched = ai
                enriched.appliedOps = [r]
                self.messages.append(enriched)
                // 不自动跳转，交由结果卡片点击触发
            }
        case "UPDATE":
            var payload: [String: AnyCodable] = [:]
            if let c = changes {
                if let t = c.title, !t.isEmpty { payload["title"] = AnyCodable(t) }
                if let s = c.startTime, !s.isEmpty { payload["startTime"] = AnyCodable(s) }
                if let e = c.endTime, !e.isEmpty { payload["endTime"] = AnyCodable(e) }
                if let loc = c.location, !loc.isEmpty { payload["location"] = AnyCodable(loc) }
                if let notes = c.notes, !notes.isEmpty { payload["notes"] = AnyCodable(notes) }
            }
            let r = updateEvent(eventId: candidateId, with: payload)
            DispatchQueue.main.async {
                let ai = VoiceMessage(content: r.success ? "已修改所选日程。" : (r.message ?? "修改失败"), isUser: false, timestamp: Date(), messageType: .text)
                var enriched = ai
                enriched.appliedOps = [r]
            self.messages.append(enriched)
            // 不自动跳转，交由结果卡片点击触发
            }
        default:
            return
        }
    }

    // 构造严格 JSON 返回的提示（会议模式）
    private func enforceMeetingJSONPrompt(basePrompt: String) -> String {
        var p = basePrompt
        p += "\n\n请严格仅返回 JSON，不要附加解释或前后缀。格式为: {\"meeting_details\":{\"title\":string,\"duration\":number,\"attendees\":[string]},\"proposed_options\":[{\"option_id\":number,\"startTime\":string,\"endTime\":string,\"reasoning\":string}],\"response\":string}。时间使用 ISO8601。"
        return p
    }

    // 构造严格 JSON 返回的提示（operations+response）
    private func enforceOperationsJSONPrompt(basePrompt: String) -> String {
        var p = basePrompt
        p += "\n\n请严格仅返回 JSON，不要附加解释或前后缀。格式为: {\"operations\":[{\"operation\":\"CREATE|UPDATE|DELETE\",\"target_event_id\":string|null,\"payload\":object}],\"response\":string}。时间一律用 ISO8601。"
        return p
    }
    
    // 构建对话上下文为一个 prompt 文本，避免依赖 OpenAIMessage 结构
    private func buildContextPrompt(currentMessage: String) -> String {
        let maxContextMessages = 10
        let recent = Array(messages.suffix(maxContextMessages))

        var lines: [String] = []
        for m in recent {
            let role = m.isUser ? "用户" : "助手"
            lines.append("[\(role)] \(m.content)")
        }
        // 若最近一条就是当前用户消息，避免重复追加
        if !(recent.last?.isUser == true && recent.last?.content == currentMessage) {
            lines.append("[用户] \(currentMessage)")
        }

        let prompt = lines.joined(separator: "\n")
        print("\n🤖 === LLM对话上下文（拼接为prompt） ===")
        print(prompt)
        print("========================\n")
        return prompt
    }

    // 组装传入 Sensor 的 records：优先外部提供者；否则使用最近对话文本作为上下文线索
    private func buildRecentStatusForSensor() -> [String] {
        if let provider = recentStatusDataProvider {
            let data = provider()
            if !data.isEmpty { return data }
        }
        // 回退：使用最近 10 条对话（含用户与助手），作为环境线索
        let maxItems = 10
        let recentMsgs = Array(messages.suffix(maxItems))
        return recentMsgs.map { m in
            let role = m.isUser ? "user" : "assistant"
            return "[\(role)] \(m.content)"
        }
    }

    // 解析AI返回的JSON到新格式（operations数组+response），兼容旧格式
    struct AIParsedResult: Codable {
        struct Operation: Codable {
            let operation: String
            let target_event_id: String?
            let payload: [String: AnyCodable]?
            let ai_metadata: [String: AnyCodable]?
        }
        let operations: [Operation]?
        let response: String?
    }

    // 仅包含顶层 response 的最小解码结构（用于回退）
    private struct OnlyResponse: Codable {
        let response: String?
    }

    // 兼容 Any 类型的解码
    struct AnyCodable: Codable {
        let value: Any
        init(_ value: Any) { self.value = value }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(Bool.self) { value = v }
            else if let v = try? container.decode(Int.self) { value = v }
            else if let v = try? container.decode(Double.self) { value = v }
            else if let v = try? container.decode(String.self) { value = v }
            else if let v = try? container.decode([AnyCodable].self) { value = v.map { $0.value } }
            else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
            else { value = "" }
        }
        func encode(to encoder: Encoder) throws { }
    }

    private func parseAIResult(from text: String) -> AIParsedResult? {
        // 提取第一个完整的 JSON 对象
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            return nil
        }
        let jsonStr = String(text[start...end])
        // 尝试解码
        if let data = jsonStr.data(using: .utf8) {
            let dec = JSONDecoder()
            do {
                return try dec.decode(AIParsedResult.self, from: data)
            } catch {
                // 回退：仅解码顶层 response 字段
                if let only = try? dec.decode(OnlyResponse.self, from: data) {
                    return AIParsedResult(operations: nil, response: only.response)
                }
            }
        }
        // 如果 JSON 里可能包含转义换行等，再试一次去除反斜杠
        let cleaned = jsonStr.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8) {
            let dec = JSONDecoder()
            if let v = try? dec.decode(AIParsedResult.self, from: data2) {
                return v
            }
            if let only = try? dec.decode(OnlyResponse.self, from: data2) {
                return AIParsedResult(operations: nil, response: only.response)
            }
        }
        return nil
    }

    // 从 operations.payload 构造 Changes（用于 UPDATE 确认文案与后续应用）
    private func buildChangesFromPayload(_ payload: [String: AnyCodable]?) -> ModifyParserResult.Changes? {
        guard let payload else { return nil }
        let title = payload["title"]?.value as? String
        let start = payload["startTime"]?.value as? String ?? payload["start"]?.value as? String
        let end = payload["endTime"]?.value as? String ?? payload["end"]?.value as? String
        let location = payload["location"]?.value as? String
        let notes = payload["notes"]?.value as? String
        if [title, start, end, location, notes].allSatisfy({ ($0 ?? "").isEmpty }) { return nil }
        return ModifyParserResult.Changes(startTime: start, endTime: end, location: location, meeting_mode: nil, add_names: nil, remove_names: nil, title: title, notes: notes)
    }

    // 生成 UPDATE 的可读变更文案
    private func formatChangesText(_ changes: ModifyParserResult.Changes?) -> String {
        guard let ch = changes else { return "请确认需要修改以下日程：" }
        var parts: [String] = ["请确认修改如下内容："]
        if let t = ch.title, !t.isEmpty { parts.append("标题 -> \(t)") }
        if let s = ch.startTime, !s.isEmpty { parts.append("开始 -> \(s)") }
        if let e = ch.endTime, !e.isEmpty { parts.append("结束 -> \(e)") }
        if let l = ch.location, !l.isEmpty { parts.append("地点 -> \(l)") }
        if let n = ch.notes, !n.isEmpty { parts.append("备注 -> \(n)") }
        return parts.joined(separator: "\n")
    }

    // 将 ModifyResolverResult.Changes 转为 ModifyParserResult.Changes
    private func toParserChanges(_ ch: ModifyResolverResult.Changes?) -> ModifyParserResult.Changes? {
        guard let ch = ch else { return nil }
        return ModifyParserResult.Changes(
            startTime: ch.startTime,
            endTime: ch.endTime,
            location: ch.location,
            meeting_mode: ch.meeting_mode,
            add_names: ch.add_names,
            remove_names: ch.remove_names,
            title: ch.title,
            notes: ch.notes
        )
    }

    private func parseMeetingResult(from text: String) -> MeetingAssistantResult? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        if let data = jsonStr.data(using: .utf8) {
            let dec = JSONDecoder()
            if let parsed = try? dec.decode(MeetingAssistantResult.self, from: data) { return parsed }
        }
        let cleaned = jsonStr.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        if let data2 = cleaned.data(using: .utf8) {
            let dec = JSONDecoder()
            return try? dec.decode(MeetingAssistantResult.self, from: data2)
        }
        return nil
    }

    private func applyOperations(_ ops: [AIParsedResult.Operation]) -> [AppliedOperationSummary] {
        var results: [AppliedOperationSummary] = []
        for op in ops {
            let kind = op.operation.uppercased()
            switch kind {
            case "CREATE":
                let r = createEvent(from: op.payload)
                results.append(r)
            case "UPDATE":
                let r = updateEvent(eventId: op.target_event_id, with: op.payload)
                results.append(r)
            case "DELETE":
                let r = deleteEvent(eventId: op.target_event_id, occurrenceStart: nil)
                results.append(r)
            default:
                results.append(AppliedOperationSummary(operation: kind, targetEventId: op.target_event_id, title: nil, startTime: nil, endTime: nil, success: false, message: "不支持的操作类型"))
            }
        }
        return results
    }

    private func createEvent(from payload: [String: AnyCodable]?) -> AppliedOperationSummary {
        guard let payload = payload else {
            return AppliedOperationSummary(operation: "CREATE", targetEventId: nil, title: nil, startTime: nil, endTime: nil, success: false, message: "缺少payload")
        }
    let title = (payload["title"]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // 支持 startTime/endTime 与 start/end 两种键名
    let startStr = (payload["startTime"]?.value as? String) ?? (payload["start"]?.value as? String)
    let endStr = (payload["endTime"]?.value as? String) ?? (payload["end"]?.value as? String)
        let location = payload["location"]?.value as? String
        let notes = payload["notes"]?.value as? String
    guard let sStr = startStr, let eStr = endStr, let s = parseFlexibleDate(sStr), let e = parseFlexibleDate(eStr) else {
            return AppliedOperationSummary(operation: "CREATE", targetEventId: nil, title: title, startTime: startStr, endTime: endStr, success: false, message: "时间解析失败")
        }

        let ev = EKEvent(eventStore: eventStore)
        ev.calendar = eventStore.defaultCalendarForNewEvents ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
        ev.title = title
        ev.startDate = s
        ev.endDate = e
        if let loc = location, !loc.isEmpty { ev.location = loc }
        if let n = notes, !n.isEmpty { ev.notes = n }
        do {
            if ev.calendar == nil {
                ev.calendar = eventStore.defaultCalendarForNewEvents ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
            }
            try eventStore.save(ev, span: EKSpan.thisEvent, commit: true)
            return AppliedOperationSummary(operation: "CREATE", targetEventId: ev.eventIdentifier, title: ev.title, startTime: iso8601.string(from: s), endTime: iso8601.string(from: e), success: true, message: nil)
        } catch {
            return AppliedOperationSummary(operation: "CREATE", targetEventId: nil, title: title, startTime: startStr, endTime: endStr, success: false, message: error.localizedDescription)
        }
    }

    private func updateEvent(eventId: String?, with payload: [String: AnyCodable]?) -> AppliedOperationSummary {
        guard let eventId = eventId, let ev = eventStore.event(withIdentifier: eventId) else {
            return AppliedOperationSummary(operation: "UPDATE", targetEventId: eventId, title: nil, startTime: nil, endTime: nil, success: false, message: "找不到目标事件")
        }
        let oldTitle = ev.title ?? ""
        var newTitle = oldTitle
        var startStrOut: String? = nil
        var endStrOut: String? = nil
        if let payload = payload {
            if let t = payload["title"]?.value as? String { ev.title = t; newTitle = t }
            // 同时支持 startTime/endTime 与 start/end
            let oldStart = ev.startDate
            let oldEnd = ev.endDate
            if let sStr = (payload["startTime"]?.value as? String) ?? (payload["start"]?.value as? String) {
                if let base = oldStart, let s = parseFlexibleDateOrTime(sStr, defaultDate: base) {
                    ev.startDate = s; startStrOut = sStr
                }
            }
            if let eStr = (payload["endTime"]?.value as? String) ?? (payload["end"]?.value as? String) {
                let baseForEnd = ev.startDate ?? oldStart ?? Date()
                if let e = parseFlexibleDateOrTime(eStr, defaultDate: baseForEnd) {
                    ev.endDate = e; endStrOut = eStr
                }
            }
            // 若仅提供了新的 start 而未提供 end，则保持原持续时长
            if startStrOut != nil && endStrOut == nil, let os = oldStart, let oe = oldEnd, let ns = ev.startDate {
                let duration = oe.timeIntervalSince(os)
                ev.endDate = ns.addingTimeInterval(max(0, duration))
                endStrOut = iso8601.string(from: ev.endDate)
            }
            if let loc = payload["location"]?.value as? String { ev.location = loc }
            if let notes = payload["notes"]?.value as? String { ev.notes = notes }
        }
        do {
            if ev.calendar == nil {
                ev.calendar = eventStore.defaultCalendarForNewEvents ?? GlobalEventStore.shared.defaultCalendarForNewEvents()
            }
            try eventStore.save(ev, span: EKSpan.thisEvent, commit: true)
            return AppliedOperationSummary(operation: "UPDATE", targetEventId: ev.eventIdentifier, title: newTitle, startTime: startStrOut, endTime: endStrOut, success: true, message: nil)
        } catch {
            return AppliedOperationSummary(operation: "UPDATE", targetEventId: ev.eventIdentifier, title: newTitle, startTime: startStrOut, endTime: endStrOut, success: false, message: error.localizedDescription)
        }
    }

    private func deleteEvent(eventId: String?, occurrenceStart: Date?) -> AppliedOperationSummary {
        guard let eventId = eventId, let ev = eventStore.event(withIdentifier: eventId) else {
            return AppliedOperationSummary(operation: "DELETE", targetEventId: eventId, title: nil, startTime: nil, endTime: nil, success: false, message: "找不到目标事件")
        }
        do {
            // 若传入 occurrenceStart，则先用 occurrence 获取该实例再删除；否则按当前 ev 删除
            if let occStart = occurrenceStart {
                if let occ = eventStore.event(withIdentifier: eventId)?.copy() as? EKEvent, let series = eventStore.event(withIdentifier: eventId) {
                    // 查找 occurrence：使用 predicate 在 occurrenceStart 当天窗口内匹配同一主事件的实例
                    let cal = Calendar.current
                    let dayStart = cal.startOfDay(for: occStart)
                    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
                    let pred = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: [series.calendar])
                    let matches = eventStore.events(matching: pred).filter { e in
                        guard let sid = e.eventIdentifier else { return false }
                        // 对于重复事件，occurrence 的 eventIdentifier 仍是同一串 ID，需用开始时间来判定具体实例
                        let sameId = sid == eventId
                        return sameId && (abs((e.startDate?.timeIntervalSince(occStart) ?? 0)) < 1)
                    }
                    if let target = matches.first {
                        try eventStore.remove(target, span: .thisEvent, commit: true)
                        return AppliedOperationSummary(operation: "DELETE", targetEventId: target.eventIdentifier, title: target.title, startTime: iso8601.string(from: target.startDate), endTime: iso8601.string(from: target.endDate), success: true, message: nil)
                    }
                }
            }
            try eventStore.remove(ev, span: EKSpan.thisEvent, commit: true)
            return AppliedOperationSummary(operation: "DELETE", targetEventId: eventId, title: ev.title, startTime: iso8601.string(from: ev.startDate), endTime: iso8601.string(from: ev.endDate), success: true, message: nil)
        } catch {
            return AppliedOperationSummary(operation: "DELETE", targetEventId: eventId, title: ev.title, startTime: iso8601.string(from: ev.startDate), endTime: iso8601.string(from: ev.endDate), success: false, message: error.localizedDescription)
        }
    }

    // 弹性解析 ISO8601 字符串，兼容有/无毫秒
    private func parseFlexibleDate(_ str: String) -> Date? {
        if let d = iso8601.date(from: str) { return d }
        if let d = iso8601NoFraction.date(from: str) { return d }
        // 最后再用 DateFormatter 尝试常见格式
        let df1 = DateFormatter()
        df1.locale = Locale(identifier: "en_US_POSIX")
        df1.timeZone = TimeZone.current
        df1.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX" // 例如 2025-09-07T15:00:00+08:00
        if let d = df1.date(from: str) { return d }
        let df2 = DateFormatter()
        df2.locale = Locale(identifier: "en_US_POSIX")
        df2.timeZone = TimeZone.current
        df2.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX" // 无秒
        if let d = df2.date(from: str) { return d }
        return nil
    }
    
    // 支持仅时间 ISO（如 "T16:00:00+08:00"），用 defaultDate 的年月日补齐
    private func parseFlexibleDateOrTime(_ str: String, defaultDate: Date) -> Date? {
        if let full = parseFlexibleDate(str) { return full }
        guard str.hasPrefix("T") else { return nil }
        let ymd = DateFormatter()
        ymd.locale = Locale(identifier: "en_US_POSIX")
        ymd.timeZone = TimeZone.current
        ymd.dateFormat = "yyyy-MM-dd"
        let day = ymd.string(from: defaultDate)
        let composed = day + str
        return parseFlexibleDate(composed)
    }
    
    private func addErrorMessage(_ errorText: String) {
        let errorMessage = VoiceMessage(
            content: errorText,
            isUser: false,
            timestamp: Date(),
            messageType: .text,
            audioFileURL: nil,
            audioDuration: nil
        )
        messages.append(errorMessage)
    }

    // MARK: - Public Methods for External Use
    /// 添加一条消息到聊天记录
    func addMessage(_ content: String, isUser: Bool = true) {
        let message = VoiceMessage(
            content: content,
            isUser: isUser,
            timestamp: Date(),
            messageType: .text,
            audioFileURL: nil,
            audioDuration: nil
        )
        messages.append(message)
    }

    // MARK: - Utility Methods
    func clearMessages() {
        stopPlaying()
        stopVoiceRecording()
        isAIResponding = false
        isTranscribing = false
        messages.removeAll()
        // 可选：删除音频文件以节省空间
        cleanupAudioFiles()
    }
    
    private func cleanupAudioFiles() {
        for message in messages {
            if let audioURL = message.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Friendly Alert Helper
    private func presentFriendlyAlert(title: String, message: String) {
        DispatchQueue.main.async {
            self.friendlyAlertState = FriendlyAlertState(title: title, message: message)
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension VoiceChatService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("录音未成功完成")
            isRecording = false
            isTranscribing = false
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("录音编码错误: \(error)")
            isRecording = false
            isTranscribing = false
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension VoiceChatService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.playingMessageId = nil
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            print("播放解码错误: \(error)")
        }
        DispatchQueue.main.async {
            self.isPlaying = false
            self.playingMessageId = nil
        }
    }
}

// MARK: - Navigation Notification
extension Notification.Name {
    static let voiceChatNavigateToDay = Notification.Name("voiceChatNavigateToDay")
}
