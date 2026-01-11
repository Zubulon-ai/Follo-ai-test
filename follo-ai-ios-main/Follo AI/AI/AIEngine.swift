//
//  AIEngine.swift
//  Follo AI
//
//  AI 引擎门面：统一切换后端模式与直连模式
//

import Foundation
import EventKit

/// AI 引擎响应结果
struct AIEngineResult {
    /// 主要显示文本（给用户看的回复）
    let displayText: String
    
    /// Agent A 的情境标签（仅直连模式）
    let contextTags: [ContextTag]
    
    /// Agent B 的通知建议（仅直连模式）
    let notifications: [NotificationItem]
    
    /// 调试信息
    let debugInfo: String
    
    /// 是否为直连模式
    let isDirectMode: Bool
    
    /// 原始后端响应（仅后端模式）
    let backendRawResponse: String?
    
    /// 错误信息（如果有）
    let errorMessage: String?
    
    /// 是否成功
    var isSuccess: Bool {
        return errorMessage == nil
    }
    
    // MARK: - 便捷构造器
    
    /// 创建直连模式成功结果
    static func directSuccess(orchestratorResult: ABOrchestratorResult) -> AIEngineResult {
        return AIEngineResult(
            displayText: orchestratorResult.displayText,
            contextTags: orchestratorResult.tagsForDisplay,
            notifications: orchestratorResult.notificationsForDisplay,
            debugInfo: orchestratorResult.debugLog,
            isDirectMode: true,
            backendRawResponse: nil,
            errorMessage: orchestratorResult.errorSummary
        )
    }
    
    /// 创建后端模式成功结果
    static func backendSuccess(response: String) -> AIEngineResult {
        return AIEngineResult(
            displayText: response,
            contextTags: [],
            notifications: [],
            debugInfo: "后端模式响应",
            isDirectMode: false,
            backendRawResponse: response,
            errorMessage: nil
        )
    }
    
    /// 创建错误结果
    static func failure(error: String, isDirectMode: Bool) -> AIEngineResult {
        return AIEngineResult(
            displayText: "请求失败: \(error)",
            contextTags: [],
            notifications: [],
            debugInfo: "错误: \(error)",
            isDirectMode: isDirectMode,
            backendRawResponse: nil,
            errorMessage: error
        )
    }
    
    /// 创建 API Key 未配置的降级结果
    static func apiKeyNotConfigured() -> AIEngineResult {
        return AIEngineResult(
            displayText: "DashScope API Key 未配置，请在 Info.plist 中设置",
            contextTags: [],
            notifications: [],
            debugInfo: "API Key 未配置，直连模式不可用",
            isDirectMode: true,
            backendRawResponse: nil,
            errorMessage: "API Key 未配置"
        )
    }
}

/// AI 引擎：统一管理后端模式与直连模式
class AIEngine {
    
    static let shared = AIEngine()
    
    private let orchestrator = ABOrchestrator.shared
    private let backendAPI = BackendAPIService()
    
    private init() {}
    
    // MARK: - 模式判断
    
    /// 当前是否使用直连模式
    var isDirectMode: Bool {
        return AppConfig.directDashScopeEnabled
    }
    
    /// 直连模式是否可用（开关开启且有 API Key）
    var isDirectModeAvailable: Bool {
        return AppConfig.isDirectModeAvailable
    }
    
    // MARK: - 核心聊天方法
    
    /// 通用聊天接口
    /// - Parameters:
    ///   - userText: 用户输入
    ///   - userInfo: 用户信息（后端模式使用）
    ///   - calendarEvents: 日历事件（后端模式使用）
    ///   - recentStatusData: 最近状态数据（后端模式使用）
    /// - Returns: AI 引擎结果
    func chat(
        userText: String,
        userInfo: UserInfo? = nil,
        calendarEvents: [EKEvent]? = nil,
        recentStatusData: [String] = []
    ) async -> AIEngineResult {
        
        // 判断使用哪种模式
        if isDirectMode {
            return await chatDirect(userText: userText)
        } else {
            return await chatBackend(
                userText: userText,
                userInfo: userInfo,
                calendarEvents: calendarEvents,
                recentStatusData: recentStatusData
            )
        }
    }
    
    // MARK: - 直连模式
    
    /// 直连模式聊天（A/B 智能体串联）
    private func chatDirect(userText: String) async -> AIEngineResult {
        print("🔗 [AIEngine] 使用直连模式 (DashScope A/B)")
        
        // 检查 API Key
        guard AppConfig.dashScopeAPIKey != nil else {
            print("⚠️ [AIEngine] API Key 未配置")
            return .apiKeyNotConfigured()
        }
        
        // 调用 A/B 编排器
        let result = await orchestrator.run(userText: userText)
        
        return .directSuccess(orchestratorResult: result)
    }
    
    // MARK: - 后端模式
    
    /// 后端模式聊天
    private func chatBackend(
        userText: String,
        userInfo: UserInfo?,
        calendarEvents: [EKEvent]?,
        recentStatusData: [String]
    ) async -> AIEngineResult {
        print("🌐 [AIEngine] 使用后端模式")
        
        do {
            let response = try await backendAPI.chat(
                prompt: userText,
                userInfo: userInfo,
                calendarEvents: calendarEvents,
                recentStatusData: recentStatusData
            )
            return .backendSuccess(response: response)
        } catch {
            print("❌ [AIEngine] 后端请求失败: \(error)")
            return .failure(error: error.localizedDescription, isDirectMode: false)
        }
    }
    
    // MARK: - 快速创建
    
    /// 快速创建接口
    func quickCreate(
        prompt: String,
        userInfo: UserInfo? = nil,
        calendarEvents: [EKEvent]? = nil,
        recentStatusData: [String] = []
    ) async -> AIEngineResult {
        
        if isDirectMode {
            // 直连模式下，使用 A/B 串联
            return await chatDirect(userText: "[快速创建] \(prompt)")
        } else {
            // 后端模式
            do {
                let response = try await backendAPI.quickCreate(
                    prompt: prompt,
                    userInfo: userInfo,
                    calendarEvents: calendarEvents,
                    recentStatusData: recentStatusData
                )
                return .backendSuccess(response: response)
            } catch {
                return .failure(error: error.localizedDescription, isDirectMode: false)
            }
        }
    }
    
    // MARK: - 仅 Agent A（情境分析）
    
    /// 仅调用 Agent A 进行情境分析
    func analyzeContext(userText: String) async -> (tags: [ContextTag], rationale: String?, error: String?) {
        guard isDirectModeAvailable else {
            return (tags: [], rationale: nil, error: "直连模式不可用")
        }
        
        let (result, _, error) = await orchestrator.runAgentAOnly(userText: userText)
        
        if let err = error {
            return (tags: [], rationale: nil, error: err.localizedDescription)
        }
        
        return (tags: result.tags, rationale: result.rationale, error: nil)
    }
    
    // MARK: - 仅 Agent B（通知生成）
    
    /// 仅调用 Agent B 生成通知
    func generateNotifications(prompt: String) async -> (notifications: [NotificationItem], error: String?) {
        guard isDirectModeAvailable else {
            return (notifications: [], error: "直连模式不可用")
        }
        
        let (result, _, error) = await orchestrator.runAgentBOnly(prompt: prompt)
        
        if let err = error {
            return (notifications: [], error: err.localizedDescription)
        }
        
        return (notifications: result.notifications, error: nil)
    }
}

// MARK: - OpenAIService 扩展（保持兼容）

extension OpenAIService {
    
    /// 使用 AIEngine 进行聊天（自动切换模式）
    func chatWithEngine(
        prompt: String,
        userInfo: UserInfo?,
        calendarEvents: [EKEvent]?,
        recentStatusData: [String]
    ) async -> AIEngineResult {
        return await AIEngine.shared.chat(
            userText: prompt,
            userInfo: userInfo,
            calendarEvents: calendarEvents,
            recentStatusData: recentStatusData
        )
    }
}
