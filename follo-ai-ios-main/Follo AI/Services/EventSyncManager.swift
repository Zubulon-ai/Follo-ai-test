//
//  EventSyncManager.swift
//  Follo AI
//
//  Created by Henry on 2025-11-03
//

import Foundation
import EventKit
import EventKitUI

/// 事件同步管理器
/// 负责从 EventKit 获取事件并同步到后端数据库
class EventSyncManager: ObservableObject {
    // MARK: - Properties

    /// 事件存储
    private let eventStore = GlobalEventStore.shared.store

    /// 后端 API 服务
    private let apiService = BackendAPIService()

    /// 是否正在同步
    @Published var isSyncing: Bool = false

    /// 同步状态消息
    @Published var syncStatusMessage: String = ""

    /// 最后同步时间
    @Published var lastSyncTime: Date?

    /// 最小同步间隔（秒）- 防止频繁同步
    private let minSyncInterval: TimeInterval = 60

    /// 上次同步时间戳
    private var lastSyncTimestamp: Date?

    // MARK: - Initializer

    init() {
        print("📅 EventSyncManager 初始化完成")
        // 移除App启动时的立即同步，改为在鉴权成功后手动触发
    }

    // MARK: - Public Methods

    /// 立即同步事件
    /// - Parameter days: 同步未来N天的事件，默认5天
    func syncNow(days: Int = 5) async {
        await syncEvents(days: days)
    }

    /// 鉴权成功后立即同步并开始定期同步
    /// 这是在用户成功登录后调用的方法
    func authenticateAndSync() async {
        print("🔐 鉴权成功，开始事件同步...")

        // 立即同步一次
        print("🚀 鉴权后立即同步事件...")
        await syncEvents()

        // 开始定期同步
        startPeriodicSync()
    }

    /// 内部同步方法（公开供 UserSession 调用）
    /// - Parameter days: 同步未来N天的事件，默认5天
    func syncEvents(days: Int = 5) async {
        await performEventSync(days: days)
    }

    /// 获取未来事件
    func getUpcomingEvents(days: Int = 5) async throws -> [EventResponse] {
        print("🔍 获取未来 \(days) 天的事件...")

        let response = try await apiService.getUpcomingEvents(days: days)
        print("✅ 获取到 \(response.count) 个未来事件")
        return response.events
    }

    /// 自动触发同步（在用户登录时调用）
    func startPeriodicSync() {
        print("🔄 开始定期同步...")

        // 不再立即同步一次 - 避免重复调用
        // 立即同步可能会与后台的定期同步重叠，导致重复处理

        // 设置定期同步（每5分钟）
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task {
                await self?.syncEvents()
            }
        }
    }

    // MARK: - Private Methods

    /// 内部实现：从 EventKit 获取事件并同步到后端
    private func performEventSync(days: Int = 5) async {
        // 检查是否在最小同步间隔内
        if let lastSync = lastSyncTimestamp {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < minSyncInterval {
                print("⏱️ 距离上次同步仅 \(Int(timeSinceLastSync)) 秒，跳过此次同步以避免重复调用")
                return
            }
        }

        DispatchQueue.main.async {
            self.isSyncing = true
            self.syncStatusMessage = "🔄 开始事件同步..."
        }

        // 记录同步开始时间
        lastSyncTimestamp = Date()

        do {
            // 1. 请求日历访问权限
            let hasAccess = await GlobalEventStore.shared.requestAccessIfNeeded()
            guard hasAccess else {
                DispatchQueue.main.async {
                    self.syncStatusMessage = "⚠️ 用户拒绝了日历访问权限"
                    self.isSyncing = false
                }
                throw EventSyncError.calendarAccessDenied
            }

            DispatchQueue.main.async {
                self.syncStatusMessage = "✅ 已获得日历访问权限"
            }

            // 2. 从 EventKit 获取事件
            let ekEvents = try await fetchEventsFromEventKit(days: days)
            print("📱 从 EventKit 获取到 \(ekEvents.count) 个事件")

            // 3. 转换事件格式
            let eventCreates = convertEKEventsToEventCreates(ekEvents)
            print("🔄 转换为 \(eventCreates.count) 个 EventCreate 对象")

            // 4. 同步到后端
            DispatchQueue.main.async {
                self.syncStatusMessage = "☁️ 正在同步到后端..."
            }

            let response = try await apiService.syncEvents(eventCreates)
            print("✅ 同步成功: \(response.message)")

            // 5. 更新同步状态
            // 注意：不再手动调用 triggerAutoSync()
            // syncEvents 内部已经异步处理了 planner 策略更新

            // 6. 更新同步状态
            DispatchQueue.main.async {
                self.lastSyncTime = Date()
                self.syncStatusMessage = "✅ 同步完成: \(response.synced_count) 个事件"
                self.isSyncing = false
            }

        } catch {
            print("❌ 同步失败: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.syncStatusMessage = "❌ 同步失败: \(error.localizedDescription)"
                self.isSyncing = false
            }
        }
    }

    /// 从 EventKit 获取事件
    private func fetchEventsFromEventKit(days: Int = 5) async throws -> [EKEvent] {
        let calendar = Calendar.current
        let now = Date()
        let startDate = now
        let endDate = calendar.date(byAdding: .day, value: days, to: now) ?? now

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)

        // 按开始时间排序
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// 将 EKEvent 转换为 EventCreate
    private func convertEKEventsToEventCreates(_ events: [EKEvent]) -> [EventCreate] {
        return events.compactMap { event in
            guard let startDate = event.startDate,
                  let endDate = event.endDate else {
                return nil
            }

            let eventType = categorizeEvent(event.title ?? "")

            return EventCreate(
                source_event_id: event.eventIdentifier,
                title: event.title ?? "无标题",
                start_at: iso8601String(from: startDate),
                end_at: iso8601String(from: endDate),
                state: "PLANNED",
                event_type: eventType,
                location: event.location,
                notes: event.notes,
                is_all_day: event.isAllDay,
                timezone: TimeZone.current.identifier
            )
        }
    }

    /// 根据事件标题分类
    private func categorizeEvent(_ title: String) -> String {
        let titleLower = title.lowercased()

        if titleLower.contains("meeting") || titleLower.contains("会议") || titleLower.contains("会") {
            return "MEETING"
        } else if titleLower.contains("work") || titleLower.contains("工作") || titleLower.contains("任务") {
            return "WORK"
        } else if titleLower.contains("fitness") || titleLower.contains("运动") || titleLower.contains("跑步") || titleLower.contains("健身") {
            return "FITNESS"
        } else if titleLower.contains("dinner") || titleLower.contains("lunch") || titleLower.contains("午餐") || titleLower.contains("晚餐") || titleLower.contains("吃") {
            return "MEAL"
        } else if titleLower.contains("travel") || titleLower.contains("旅行") || titleLower.contains("出差") {
            return "TRAVEL"
        } else if titleLower.contains("study") || titleLower.contains("学习") || titleLower.contains("课") {
            return "STUDY"
        } else {
            return "OTHER"
        }
    }

    /// 将 Date 转换为 ISO8601 字符串
    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return formatter.string(from: date)
    }
}

// MARK: - Error Types

enum EventSyncError: Error, LocalizedError {
    case calendarAccessDenied
    case noEventsFound

    var errorDescription: String? {
        switch self {
        case .calendarAccessDenied:
            return "需要日历访问权限才能同步日程"
        case .noEventsFound:
            return "未找到任何事件"
        }
    }
}
