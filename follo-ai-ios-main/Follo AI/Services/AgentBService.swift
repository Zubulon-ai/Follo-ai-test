//
//  AgentBService.swift
//  Follo AI
//
//  Agent B 服务：通知生成与任务建议
//

import Foundation

/// Agent B 服务
class AgentBService {
    
    static let shared = AgentBService()
    
    private let client = DashScopeClient.shared
    
    private init() {}
    
    // MARK: - 核心方法
    
    /// 基于 Agent A 的结果生成通知建议
    /// - Parameters:
    ///   - userText: 用户原始输入
    ///   - agentAResult: Agent A 的解析结果
    /// - Returns: (raw: 原始响应, parsed: 解析后的结果)
    func trigger(userText: String, agentAResult: AgentAResult) async throws -> (raw: String, parsed: AgentBResult) {
        print("🅱️ [AgentB] 开始生成通知建议...")
        
        // 构建包含 Agent A 上下文的 Prompt
        let enhancedPrompt = buildPromptWithContext(userText: userText, agentAResult: agentAResult)
        
        print("🅱️ [AgentB] 增强 Prompt: \(enhancedPrompt.prefix(300))...")
        
        // 调用 Agent B
        let rawResponse = try await client.callAgentB(prompt: enhancedPrompt)
        
        print("🅱️ [AgentB] 原始响应: \(rawResponse.prefix(500))...")
        
        // 解析结果
        let parsed = AgentParse.parseAgentBResult(from: rawResponse)
        
        print("🅱️ [AgentB] 解析结果:")
        print("   - notifications: \(parsed.notifications.count) 条")
        for (i, notif) in parsed.notifications.enumerated() {
            print("     [\(i+1)] \(notif.severityIcon) \(notif.title)")
        }
        if let tasks = parsed.pinnedTasks {
            print("   - pinnedTasks: \(tasks.joined(separator: ", "))")
        }
        
        return (raw: rawResponse, parsed: parsed)
    }
    
    // MARK: - Prompt 构建
    
    /// 构建包含 Agent A 上下文的 Prompt
    private func buildPromptWithContext(userText: String, agentAResult: AgentAResult) -> String {
        var parts: [String] = []
        
        // 用户原始输入
        parts.append("[用户输入]\n\(userText)")
        
        // Agent A 的上下文摘要
        let contextSummary = agentAResult.summaryForAgentB()
        parts.append("[情境分析结果]\n\(contextSummary)")
        
        // 添加指令
        parts.append("[任务]\n请基于以上用户输入和情境分析，生成适当的通知建议。")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - 独立调用（不依赖 Agent A）
    
    /// 直接调用 Agent B（不经过 Agent A）
    func directTrigger(prompt: String) async throws -> (raw: String, parsed: AgentBResult) {
        print("🅱️ [AgentB] 直接调用模式...")
        
        let rawResponse = try await client.callAgentB(prompt: prompt)
        let parsed = AgentParse.parseAgentBResult(from: rawResponse)
        
        return (raw: rawResponse, parsed: parsed)
    }
}
