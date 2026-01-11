//
//  ABOrchestrator.swift
//  Follo AI
//
//  A/B 智能体编排器：串联 Agent A 和 Agent B
//

import Foundation

/// A/B 编排结果
struct ABOrchestratorResult {
    let agentAResult: AgentAResult
    let agentBResult: AgentBResult?
    let debugLog: String
    
    /// Agent A 原始响应
    let agentARaw: String
    /// Agent B 原始响应（可能为空）
    let agentBRaw: String?
    
    /// 是否成功完成完整流程
    var isComplete: Bool {
        return agentBResult != nil
    }
    
    /// 获取主要显示文本
    var displayText: String {
        if let bResult = agentBResult, !bResult.notifications.isEmpty {
            return bResult.notifications.map { "\($0.severityIcon) \($0.title)" }.joined(separator: "\n")
        }
        if let rationale = agentAResult.rationale, !rationale.isEmpty {
            return rationale
        }
        return "处理完成"
    }
}

/// A/B 编排器
class ABOrchestrator {
    
    static let shared = ABOrchestrator()
    
    private let agentA = AgentAService.shared
    private let agentB = AgentBService.shared
    
    private init() {}
    
    // MARK: - 核心编排方法
    
    /// 执行 A -> B 串联调用
    /// - Parameter userText: 用户输入
    /// - Returns: 编排结果
    func run(userText: String) async -> ABOrchestratorResult {
        var debugLines: [String] = []
        debugLines.append("=== ABOrchestrator 开始 ===")
        debugLines.append("时间: \(ISO8601DateFormatter().string(from: Date()))")
        debugLines.append("输入: \(userText.prefix(100))...")
        debugLines.append("")
        
        // Step 1: 调用 Agent A
        debugLines.append("--- Step 1: Agent A ---")
        
        var agentAResult: AgentAResult = .empty
        var agentARaw: String = ""
        
        do {
            let (raw, parsed) = try await agentA.inferContext(userText: userText)
            agentARaw = raw
            agentAResult = parsed
            
            debugLines.append("✅ Agent A 成功")
            debugLines.append("   intent: \(parsed.intent ?? "(无)")")
            debugLines.append("   tags: \(parsed.tags.count) 个")
            debugLines.append("   raw (前200字): \(raw.prefix(200))")
            debugLines.append("")
        } catch {
            debugLines.append("❌ Agent A 失败: \(error.localizedDescription)")
            debugLines.append("")
            
            // Agent A 失败，返回降级结果
            let debugLog = debugLines.joined(separator: "\n")
            return ABOrchestratorResult(
                agentAResult: .empty,
                agentBResult: nil,
                debugLog: debugLog,
                agentARaw: "",
                agentBRaw: nil
            )
        }
        
        // Step 2: 调用 Agent B
        debugLines.append("--- Step 2: Agent B ---")
        
        var agentBResult: AgentBResult? = nil
        var agentBRaw: String? = nil
        
        do {
            let (raw, parsed) = try await agentB.trigger(userText: userText, agentAResult: agentAResult)
            agentBRaw = raw
            agentBResult = parsed
            
            debugLines.append("✅ Agent B 成功")
            debugLines.append("   notifications: \(parsed.notifications.count) 条")
            debugLines.append("   raw (前200字): \(raw.prefix(200))")
            debugLines.append("")
        } catch {
            debugLines.append("⚠️ Agent B 失败: \(error.localizedDescription)")
            debugLines.append("   (Agent A 结果仍然有效)")
            debugLines.append("")
            
            // Agent B 失败不阻塞，继续返回 Agent A 结果
        }
        
        debugLines.append("=== ABOrchestrator 结束 ===")
        
        let debugLog = debugLines.joined(separator: "\n")
        
        return ABOrchestratorResult(
            agentAResult: agentAResult,
            agentBResult: agentBResult,
            debugLog: debugLog,
            agentARaw: agentARaw,
            agentBRaw: agentBRaw
        )
    }
    
    // MARK: - 仅调用 Agent A
    
    /// 仅执行 Agent A（不串联 B）
    func runAgentAOnly(userText: String) async -> (result: AgentAResult, raw: String, error: Error?) {
        do {
            let (raw, parsed) = try await agentA.inferContext(userText: userText)
            return (result: parsed, raw: raw, error: nil)
        } catch {
            return (result: .empty, raw: "", error: error)
        }
    }
    
    // MARK: - 仅调用 Agent B
    
    /// 仅执行 Agent B（直接调用，不依赖 A）
    func runAgentBOnly(prompt: String) async -> (result: AgentBResult, raw: String, error: Error?) {
        do {
            let (raw, parsed) = try await agentB.directTrigger(prompt: prompt)
            return (result: parsed, raw: raw, error: nil)
        } catch {
            return (result: .empty, raw: "", error: error)
        }
    }
}

// MARK: - 便捷扩展

extension ABOrchestratorResult {
    
    /// 生成用于 UI 显示的标签列表
    var tagsForDisplay: [ContextTag] {
        return agentAResult.tags
    }
    
    /// 生成用于 UI 显示的通知列表
    var notificationsForDisplay: [NotificationItem] {
        return agentBResult?.notifications ?? []
    }
    
    /// 错误摘要（如果有）
    var errorSummary: String? {
        if agentAResult.tags.isEmpty && agentBResult == nil {
            return "AI 处理失败，请稍后重试"
        }
        if agentBResult == nil {
            return "通知生成暂不可用"
        }
        return nil
    }
}
