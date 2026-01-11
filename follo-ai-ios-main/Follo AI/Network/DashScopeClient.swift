//
//  DashScopeClient.swift
//  Follo AI
//
//  DashScope 百炼应用直连客户端
//

import Foundation

/// DashScope 直连客户端错误
enum DashScopeClientError: Error, LocalizedError {
    case apiKeyNotConfigured
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "DashScope API Key 未配置，请在 Info.plist 中设置 DashScopeAPIKey"
        case .invalidURL:
            return "无效的 API URL"
        case .httpError(let code, let body):
            return "HTTP 错误 \(code): \(body.prefix(200))"
        case .decodingError(let msg):
            return "响应解析失败: \(msg)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}

/// DashScope API 响应结构
struct DashScopeResponse: Codable {
    struct Output: Codable {
        let text: String?
        let finish_reason: String?
    }
    struct Usage: Codable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
    let output: Output?
    let usage: Usage?
    let request_id: String?
}

/// DashScope 直连客户端
class DashScopeClient {
    
    static let shared = DashScopeClient()
    
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config)
    }
    
    // MARK: - 核心调用方法
    
    /// 调用 DashScope 百炼应用
    /// - Parameters:
    ///   - appId: 应用 ID
    ///   - prompt: 用户输入的 prompt
    /// - Returns: 返回的文本结果
    func callApp(appId: String, prompt: String) async throws -> String {
        // 1. 检查 API Key
        guard let apiKey = AppConfig.dashScopeAPIKey else {
            throw DashScopeClientError.apiKeyNotConfigured
        }
        
        // 2. 构建 URL
        let urlString = AppConfig.buildAppCompletionURL(appId: appId)
        guard let url = URL(string: urlString) else {
            throw DashScopeClientError.invalidURL
        }
        
        // 3. Debug 日志
        print("🔗 [DashScope] FINAL_URL: \(urlString)")
        print("🔑 [DashScope] API Key: \(AppConfig.maskedAPIKey)")
        
        // 4. 构建请求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // 5. 构建请求体
        let requestBody: [String: Any] = [
            "input": [
                "prompt": prompt
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // 6. 发送请求
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DashScopeClientError.networkError(NSError(domain: "DashScope", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]))
            }
            
            let statusCode = httpResponse.statusCode
            let responseBody = String(data: data, encoding: .utf8) ?? "(无法解码响应)"
            
            // Debug 日志
            print("📊 [DashScope] statusCode: \(statusCode)")
            print("📄 [DashScope] response body (前2000字): \(String(responseBody.prefix(2000)))")
            
            // 7. 检查 HTTP 状态码
            guard (200...299).contains(statusCode) else {
                throw DashScopeClientError.httpError(statusCode: statusCode, body: responseBody)
            }
            
            // 8. 解析响应
            return try parseResponse(data: data, rawBody: responseBody)
            
        } catch let error as DashScopeClientError {
            throw error
        } catch {
            throw DashScopeClientError.networkError(error)
        }
    }
    
    // MARK: - 响应解析
    
    private func parseResponse(data: Data, rawBody: String) throws -> String {
        // 优先尝试标准结构解析
        let decoder = JSONDecoder()
        
        if let response = try? decoder.decode(DashScopeResponse.self, from: data),
           let text = response.output?.text,
           !text.isEmpty {
            return text
        }
        
        // 尝试解析嵌套的 output.text
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let output = json["output"] as? [String: Any],
           let text = output["text"] as? String,
           !text.isEmpty {
            return text
        }
        
        // 尝试直接从 JSON 中提取 text 字段
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String,
           !text.isEmpty {
            return text
        }
        
        // 最后返回原始响应
        if !rawBody.isEmpty && rawBody != "{}" {
            print("⚠️ [DashScope] 无法解析标准格式，返回原始响应")
            return rawBody
        }
        
        throw DashScopeClientError.decodingError("响应中未找到有效的 text 字段")
    }
    
    // MARK: - 便捷方法
    
    /// 调用 Agent A
    func callAgentA(prompt: String) async throws -> String {
        return try await callApp(appId: AppConfig.agentAAppId, prompt: prompt)
    }
    
    /// 调用 Agent B
    func callAgentB(prompt: String) async throws -> String {
        return try await callApp(appId: AppConfig.agentBAppId, prompt: prompt)
    }
}
