//
//  BackendAPIService.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/10/29.
//

import Foundation
import EventKit

// MARK: - API 请求模型
struct BackendAPIRequest<T: Codable>: Codable {
    let prompt: String
    let user_info: T?
    let calendar_events: [[String: AnyCodable]]?
    let recent_status_data: [String]
}

struct BackendAPIResponse<T: Codable>: Codable {
    let success: Bool
    let data: T?
    let message: String
}

struct TextResponse: Codable {
    let text: String
}

struct HARAPIRequest: Codable {
    let user_info: [String: String]
    let calendar_json: String
    let sensor_json: String
    let current_time_info: String
}

struct RecommendationAPIRequest: Codable {
    let user_info: [String: String]
    let calendar_json: String
    let sensor_json: String
    let time: String
}

struct MeetingAssistantAPIRequest: Codable {
    let prompt_text: String
    let recipient_name: String
    let recipient_prefs_json: String
    let recipient_calendar_json: String
    let requester_name: String
    let requester_user_info: [String: String]?
    let requester_calendar_events: [[String: AnyCodable]]?
}

struct QuickCreateAPIRequest: Codable {
    let prompt: String
    let user_info: [String: String]?
    let calendar_events: [[String: AnyCodable]]?
    let recent_status_data: [String]
}

struct ContextEngineRequest: Codable {
    let trigger: String
    let snapshot: ContextSnapshot
}

struct ContextEngineResponse: Codable {
    let decision: String
    let reasoning: String?
    let notification: NotificationPayload?
}

struct NotificationPayload: Codable {
    let priority: String?
    let title: String
    let body: String
    let action_label: String?
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try container.encode(v.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

// MARK: - 后端 API 服务
class BackendAPIService {
    // 从 Info.plist 读取后端 API 基础 URL
    private static let baseURL: String = {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "BackendAPIURL") as? String else {
            fatalError("BackendAPIURL not found in Info.plist")
        }
        return url
    }()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }

    // MARK: - 通用 API 请求方法
    private func request<T: Codable, R: Codable>(
        endpoint: String,
        method: String = "POST",
        body: R,
        responseType: T.Type,
        timeoutInterval: TimeInterval = 60
    ) async throws -> T {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/dashscope/\(endpoint)") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval

        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                // 尝试刷新 Token
                if let refreshToken = KeychainService.shared.getRefreshToken() {
                    print("🔄 [BackendAPI] Token expired, attempting refresh...")
                    do {
                        let tokenResponse = try await self.refreshToken(refreshToken: refreshToken)
                        
                        // 更新 Keychain
                        _ = KeychainService.shared.setAccessToken(tokenResponse.access_token)
                        _ = KeychainService.shared.setRefreshToken(tokenResponse.refresh_token)
                        print("✅ [BackendAPI] Token refreshed successfully")
                        
                        // 重试原请求
                        var newRequest = request
                        newRequest.setValue("Bearer \(tokenResponse.access_token)", forHTTPHeaderField: "Authorization")
                        
                        let (newData, newResponse) = try await session.data(for: newRequest)
                        
                        guard let newHttpResponse = newResponse as? HTTPURLResponse else {
                            throw BackendAPIError.invalidResponse
                        }
                        
                        if (200...299).contains(newHttpResponse.statusCode) {
                            let decoder = JSONDecoder()
                            return try decoder.decode(T.self, from: newData)
                        } else {
                            throw BackendAPIError.httpError(newHttpResponse.statusCode)
                        }
                    } catch {
                        print("❌ [BackendAPI] Token refresh failed: \(error)")
                        throw BackendAPIError.unauthorized
                    }
                }
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 获取 JWT Token
    private func getJWTToken() -> String? {
        return KeychainService.shared.getAccessToken()
    }

    // MARK: - 获取当前用户信息
    func getCurrentUser() async throws -> AppleUser {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/auth/me") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // 设置10秒超时

        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AppleUser.self, from: data)
    }

    // MARK: - 刷新Token
    func refreshToken(refreshToken: String) async throws -> TokenResponse {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/auth/token/refresh") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // 设置10秒超时

        let body = ["refresh_token": refreshToken]
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(TokenResponse.self, from: data)
    }

    // MARK: - 问候接口
    func sendGreeting() async throws -> String {
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "greeting",
            body: EmptyRequest(),
            responseType: BackendAPIResponse<TextResponse>.self
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - HAR 关怀功能
    func harAnalysis(
        userInfo: UserInfo,
        calendarJSON: String,
        sensorJSON: String,
        currentTimeInfo: String
    ) async throws -> String {
        let body = HARAPIRequest(
            user_info: [
                "age": userInfo.age,
                "profession": userInfo.profession,
                "gender": userInfo.gender
            ],
            calendar_json: calendarJSON,
            sensor_json: sensorJSON,
            current_time_info: currentTimeInfo
        )
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "har",
            body: body,
            responseType: BackendAPIResponse<TextResponse>.self,
            timeoutInterval: 300  // HAR 分析需要更长的超时时间（5分钟）
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - 商业化推荐
    func fetchRecommendations(
        userInfo: UserInfo,
        calendarJSON: String,
        sensorJSON: String,
        timeInfo: String
    ) async throws -> String {
        let body = RecommendationAPIRequest(
            user_info: [
                "age": userInfo.age,
                "profession": userInfo.profession,
                "gender": userInfo.gender
            ],
            calendar_json: calendarJSON,
            sensor_json: sensorJSON,
            time: timeInfo
        )
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "recommendations",
            body: body,
            responseType: BackendAPIResponse<TextResponse>.self,
            timeoutInterval: 300  // 推荐分析需要更长的超时时间（5分钟）
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - 会议助手
    func meetingAssistant(
        promptText: String,
        recipientName: String,
        recipientPrefsJSON: String,
        recipientCalendarJSON: String,
        requesterName: String,
        requesterUserInfo: UserInfo?,
        requesterCalendarEvents: [EKEvent]?
    ) async throws -> String {
        let requesterUserInfoDict = requesterUserInfo.map { [
            "age": $0.age,
            "profession": $0.profession,
            "gender": $0.gender
        ] }

        let calendarEvents = requesterCalendarEvents?.compactMap { event -> [String: AnyCodable]? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return [
                "title": AnyCodable(event.title ?? ""),
                "location": AnyCodable(event.location ?? ""),
                "notes": AnyCodable(event.notes ?? ""),
                "start": AnyCodable(iso8601String(from: start)),
                "end": AnyCodable(iso8601String(from: end)),
                "is_all_day": AnyCodable(event.isAllDay),
                "timezone": AnyCodable(TimeZone.current.identifier),
                "schedule_type": AnyCodable(event.calendar.title)
            ]
        }.compactMap { $0 }

        let body = MeetingAssistantAPIRequest(
            prompt_text: promptText,
            recipient_name: recipientName,
            recipient_prefs_json: recipientPrefsJSON,
            recipient_calendar_json: recipientCalendarJSON,
            requester_name: requesterName,
            requester_user_info: requesterUserInfoDict,
            requester_calendar_events: calendarEvents
        )
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "meeting-assistant",
            body: body,
            responseType: BackendAPIResponse<TextResponse>.self
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - 快速创建
    func quickCreate(
        prompt: String,
        userInfo: UserInfo?,
        calendarEvents: [EKEvent]?,
        recentStatusData: [String]
    ) async throws -> String {
        let userInfoDict = userInfo.map { [
            "age": $0.age,
            "profession": $0.profession,
            "gender": $0.gender
        ] }

        let events = calendarEvents?.compactMap { event -> [String: AnyCodable]? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return [
                "title": AnyCodable(event.title ?? ""),
                "location": AnyCodable(event.location ?? ""),
                "notes": AnyCodable(event.notes ?? ""),
                "start": AnyCodable(iso8601String(from: start)),
                "end": AnyCodable(iso8601String(from: end)),
                "is_all_day": AnyCodable(event.isAllDay),
                "timezone": AnyCodable(TimeZone.current.identifier),
                "schedule_type": AnyCodable(event.calendar.title)
            ]
        }.compactMap { $0 }

        let body = QuickCreateAPIRequest(
            prompt: prompt,
            user_info: userInfoDict,
            calendar_events: events,
            recent_status_data: recentStatusData
        )
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "quick-create",
            body: body,
            responseType: BackendAPIResponse<TextResponse>.self
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - 通用聊天
    func chat(
        prompt: String,
        userInfo: UserInfo?,
        calendarEvents: [EKEvent]?,
        recentStatusData: [String]
    ) async throws -> String {
        let userInfoDict = userInfo.map { [
            "age": $0.age,
            "profession": $0.profession,
            "gender": $0.gender
        ] }

        let events = calendarEvents?.compactMap { event -> [String: AnyCodable]? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return [
                "title": AnyCodable(event.title ?? ""),
                "location": AnyCodable(event.location ?? ""),
                "notes": AnyCodable(event.notes ?? ""),
                "start": AnyCodable(iso8601String(from: start)),
                "end": AnyCodable(iso8601String(from: end)),
                "is_all_day": AnyCodable(event.isAllDay),
                "timezone": AnyCodable(TimeZone.current.identifier),
                "schedule_type": AnyCodable(event.calendar.title)
            ]
        }.compactMap { $0 }

        let body = BackendAPIRequest(
            prompt: prompt,
            user_info: userInfoDict,
            calendar_events: events,
            recent_status_data: recentStatusData
        )
        let response: BackendAPIResponse<TextResponse> = try await request(
            endpoint: "chat",
            body: body,
            responseType: BackendAPIResponse<TextResponse>.self
        )
        return response.data?.text ?? "无回复内容"
    }

    // MARK: - 事件同步方法

    /// 同步事件到后端数据库
    /// - Parameter events: 要同步的事件数组
    /// - Returns: 同步结果
    /// - Note: 使用"先删后加"策略，确保数据库中的事件与客户端一致
    func syncEvents(_ events: [EventCreate]) async throws -> EventSyncResponse {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/events/sync") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30  // 同步可能需要更长时间

        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = EventSyncRequest(events: events)
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(EventSyncResponse.self, from: data)
    }

    /// 获取未来N天的事件
    /// - Parameter days: 未来天数，默认5天
    /// - Returns: 事件列表
    func getUpcomingEvents(days: Int = 5) async throws -> EventUpcomingResponse {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/events/upcoming?days=\(days)") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(EventUpcomingResponse.self, from: data)
    }

    /// 手动触发自动同步（更新状态 + 清理）
    func triggerAutoSync() async throws -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/events/auto-sync") else {
            throw BackendAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }

        return (200...299).contains(httpResponse.statusCode)
    }

    /// 上传 Context Snapshot 到 Context Engine
    func uploadContextSnapshot(trigger: String, snapshot: ContextSnapshot) async throws -> ContextEngineResponse {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/context/engine") else {
            throw BackendAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 添加认证头
        if let token = getJWTToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let payload = ContextEngineRequest(trigger: trigger, snapshot: snapshot)
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 401 {
                throw BackendAPIError.unauthorized
            }
            throw BackendAPIError.httpError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(ContextEngineResponse.self, from: data)
    }

    // MARK: - 辅助方法
    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return formatter.string(from: date)
    }
}

// MARK: - 空请求模型
struct EmptyRequest: Codable {}

// MARK: - Token响应模型
struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let token_type: String
}

// MARK: - 事件相关模型

/// 事件创建请求模型
struct EventCreate: Codable {
    let source_event_id: String
    let title: String
    let start_at: String
    let end_at: String
    let state: String
    let event_type: String?
    let location: String?
    let notes: String?
    let is_all_day: Bool?
    let timezone: String?
}

/// 事件同步请求模型
struct EventSyncRequest: Codable {
    let events: [EventCreate]
}

/// 事件同步响应模型
struct EventSyncResponse: Codable {
    let success: Bool
    let message: String
    let synced_count: Int
}

/// 事件响应模型
struct EventResponse: Codable {
    let id: String
    let user_id: Int
    let source_event_id: String
    let title: String
    let start_at: String
    let end_at: String
    let state: String
    let event_type: String?
    let location: String?
    let notes: String?
    let is_all_day: Bool?
    let timezone: String?
    let created_at: String
    let updated_at: String
}

/// 未来事件响应模型
struct EventUpcomingResponse: Codable {
    let success: Bool
    let count: Int
    let events: [EventResponse]
    let message: String?
}

// MARK: - 错误类型
enum BackendAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .invalidResponse:
            return "无效的响应"
        case .unauthorized:
            return "未授权，请先登录"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        }
    }
}
