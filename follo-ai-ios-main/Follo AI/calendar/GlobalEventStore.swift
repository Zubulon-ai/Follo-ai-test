//
//  GlobalEventStore.swift
//  Follo AI
//
//  全局唯一的 EKEventStore 单例，避免过多实例导致 calaccessd 连接过多。
//

import Foundation
import EventKit

final class GlobalEventStore {
    static let shared = GlobalEventStore()

    let store: EKEventStore

    private init() {
        self.store = EKEventStore()
    }

    /// 请求日历访问权限（如有需要）。返回是否已获得访问权限。
    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: EKEntityType.event)
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                do {
                    let granted = try await store.requestFullAccessToEvents()
                    return granted
                } catch { return false }
            } else {
                return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    store.requestAccess(to: EKEntityType.event) { granted, _ in continuation.resume(returning: granted) }
                }
            }
        }
        if #available(iOS 17.0, *) {
            return EKEventStore.authorizationStatus(for: EKEntityType.event) == .fullAccess
        } else {
            return EKEventStore.authorizationStatus(for: EKEntityType.event) == .authorized
        }
    }

    /// 获取一个可用于新事件的日历（优先默认、可写，其次任意事件日历）。
    func defaultCalendarForNewEvents() -> EKCalendar? {
        if let def = store.defaultCalendarForNewEvents { return def }
        if let editable = store.calendars(for: EKEntityType.event).first(where: { $0.allowsContentModifications }) { return editable }
        return store.calendars(for: EKEntityType.event).first
    }
}
