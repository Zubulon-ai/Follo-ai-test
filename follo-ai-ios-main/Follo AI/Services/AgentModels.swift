//
//  AgentModels.swift
//  Follo AI
//
//  Agent A/B 输出模型定义与解析器
//

import Foundation

// MARK: - Agent A 输出模型

/// 上下文标签
struct ContextTag: Codable, Identifiable {
    let key: String
    let label: String
    let confidence: Double?
    
    var id: String { key }
    
    /// 格式化显示
    var displayText: String {
        if let conf = confidence {
            return "\(label) (\(Int(conf * 100))%)"
        }
        return label
    }
}

/// Agent A 结果：情境理解
struct AgentAResult: Codable {
    let intent: String?
    let tags: [ContextTag]
    let rationale: String?
    
    /// 空结果
    static var empty: AgentAResult {
        AgentAResult(intent: nil, tags: [], rationale: nil)
    }
    
    /// 生成给 Agent B 的上下文摘要
    func summaryForAgentB() -> String {
        var parts: [String] = []
        
        if let intent = intent, !intent.isEmpty {
            parts.append("用户意图: \(intent)")
        }
        
        if !tags.isEmpty {
            let tagSummary = tags.map { tag in
                if let conf = tag.confidence {
                    return "\(tag.key)=\(tag.label)(conf:\(String(format: "%.2f", conf)))"
                }
                return "\(tag.key)=\(tag.label)"
            }.joined(separator: ", ")
            parts.append("情境标签: [\(tagSummary)]")
        }
        
        if let rationale = rationale, !rationale.isEmpty {
            parts.append("分析: \(rationale)")
        }
        
        return parts.isEmpty ? "无额外上下文" : parts.joined(separator: "; ")
    }
}

// MARK: - Agent B 输出模型

/// 通知项
struct NotificationItem: Codable, Identifiable {
    let title: String
    let body: String?
    let severity: String?
    let actions: [String]?
    
    var id: String { title + (body ?? "") }
    
    /// 严重程度图标
    var severityIcon: String {
        switch severity?.lowercased() {
        case "high", "urgent":
            return "🔴"
        case "medium", "normal":
            return "🟡"
        case "low", "info":
            return "🟢"
        default:
            return "ℹ️"
        }
    }
}

/// Agent B 结果：通知建议
struct AgentBResult: Codable {
    let notifications: [NotificationItem]
    let pinnedTasks: [String]?
    
    /// 空结果
    static var empty: AgentBResult {
        AgentBResult(notifications: [], pinnedTasks: nil)
    }
    
    /// 是否有有效内容
    var hasContent: Bool {
        return !notifications.isEmpty || !(pinnedTasks?.isEmpty ?? true)
    }
}

// MARK: - 解析工具

/// Agent 输出解析器
struct AgentParse {
    
    /// 从文本中解码 JSON 结构
    /// - 自动去除 ```json ... ``` 包裹
    /// - 解码失败返回 nil（不崩溃）
    static func decodeJSON<T: Codable>(from text: String, as type: T.Type) -> T? {
        let cleaned = cleanJSONWrapper(text)
        
        guard let data = cleaned.data(using: .utf8) else {
            print("⚠️ [AgentParse] 无法将文本转为 Data")
            return nil
        }
        
        let decoder = JSONDecoder()
        
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("⚠️ [AgentParse] JSON 解码失败: \(error)")
            
            // 尝试宽松解析：提取第一个 JSON 对象
            if let jsonObj = extractFirstJSON(from: cleaned) {
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonObj),
                   let result = try? decoder.decode(T.self, from: jsonData) {
                    return result
                }
            }
            
            return nil
        }
    }
    
    /// 清理 JSON 包裹（```json ... ```）
    private static func cleanJSONWrapper(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 移除 ```json 开头
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        
        // 移除 ``` 结尾
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 提取文本中第一个 JSON 对象
    private static func extractFirstJSON(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        return json
    }
    
    // MARK: - 专用解析方法
    
    /// 解析 Agent A 结果
    static func parseAgentAResult(from text: String) -> AgentAResult {
        // 尝试标准解码
        if let result = decodeJSON(from: text, as: AgentAResult.self) {
            return result
        }
        
        // 尝试从 JSON 字典手动构建
        let cleaned = cleanJSONWrapper(text)
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           let data = String(cleaned[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            let intent = json["intent"] as? String
            let rationale = json["rationale"] as? String
            
            var tags: [ContextTag] = []
            if let tagsArray = json["tags"] as? [[String: Any]] {
                tags = tagsArray.compactMap { tagDict in
                    guard let key = tagDict["key"] as? String,
                          let label = tagDict["label"] as? String else { return nil }
                    let confidence = tagDict["confidence"] as? Double
                    return ContextTag(key: key, label: label, confidence: confidence)
                }
            }
            
            return AgentAResult(intent: intent, tags: tags, rationale: rationale)
        }
        
        // 降级：将原始文本作为 rationale
        return AgentAResult(intent: nil, tags: [], rationale: text)
    }
    
    /// 解析 Agent B 结果
    static func parseAgentBResult(from text: String) -> AgentBResult {
        // 尝试标准解码
        if let result = decodeJSON(from: text, as: AgentBResult.self) {
            return result
        }
        
        // 尝试从 JSON 字典手动构建
        let cleaned = cleanJSONWrapper(text)
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           let data = String(cleaned[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            var notifications: [NotificationItem] = []
            if let notifArray = json["notifications"] as? [[String: Any]] {
                notifications = notifArray.compactMap { notifDict in
                    guard let title = notifDict["title"] as? String else { return nil }
                    let body = notifDict["body"] as? String
                    let severity = notifDict["severity"] as? String
                    let actions = notifDict["actions"] as? [String]
                    return NotificationItem(title: title, body: body, severity: severity, actions: actions)
                }
            }
            
            let pinnedTasks = json["pinnedTasks"] as? [String]
            
            return AgentBResult(notifications: notifications, pinnedTasks: pinnedTasks)
        }
        
        // 降级：将原始文本作为单条通知
        return AgentBResult(
            notifications: [NotificationItem(title: "B输出非结构化", body: text, severity: "info", actions: nil)],
            pinnedTasks: nil
        )
    }
}
