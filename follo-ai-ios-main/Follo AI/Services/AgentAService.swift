//
//  AgentAService.swift
//  Follo AI
//
//  Agent A 服务：情境理解与意图识别
//

import Foundation

/// Agent A 服务
class AgentAService {
    
    static let shared = AgentAService()
    
    private let client = DashScopeClient.shared
    
    private init() {}
    
    // MARK: - 核心方法
    
    /// 推断用户上下文
    /// - Parameter userText: 用户输入文本
    /// - Returns: (raw: 原始响应, parsed: 解析后的结果)
    func inferContext(userText: String) async throws -> (raw: String, parsed: AgentAResult) {
        print("🅰️ [AgentA] 开始情境推断...")
        print("🅰️ [AgentA] 输入: \(userText.prefix(100))...")
        
        // 调用 Agent A
        let rawResponse = try await client.callAgentA(prompt: userText)
        
        print("🅰️ [AgentA] 原始响应: \(rawResponse.prefix(500))...")
        
        // 解析结果
        let parsed = AgentParse.parseAgentAResult(from: rawResponse)
        
        print("🅰️ [AgentA] 解析结果:")
        print("   - intent: \(parsed.intent ?? "(无)")")
        print("   - tags: \(parsed.tags.map { $0.displayText }.joined(separator: ", "))")
        print("   - rationale: \(parsed.rationale?.prefix(100) ?? "(无)")...")
        
        return (raw: rawResponse, parsed: parsed)
    }
    
    // MARK: - 构建增强 Prompt
    
    /// 构建包含上下文信息的增强 Prompt
    /// - Parameters:
    ///   - userText: 用户原始输入
    ///   - contextSignals: 可选的上下文信号（如位置、运动状态等）
    /// - Returns: 增强后的 Prompt
    static func buildEnhancedPrompt(userText: String, contextSignals: [String: Any]? = nil) -> String {
        var promptParts: [String] = []
        
        // 添加上下文信号（如果有）
        if let signals = contextSignals, !signals.isEmpty {
            let signalStr = signals.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            promptParts.append("[环境信号] \(signalStr)")
        }
        
        // 添加用户输入
        promptParts.append("[用户输入] \(userText)")
        
        return promptParts.joined(separator: "\n")
    }
}
