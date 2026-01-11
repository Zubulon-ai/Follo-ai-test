//
//  TokenRefreshManager.swift
//  Follo AI
//
//  自动刷新 JWT Token，确保后台任务始终有有效的 Token
//

import Foundation
import UIKit
import BackgroundTasks

class TokenRefreshManager {
    static let shared = TokenRefreshManager()
    
    private let keychainService = KeychainService.shared
    private let backendService = BackendAPIService()
    
    // Token 刷新间隔（默认 50 分钟，假设 Token 有效期为 1 小时）
    private let refreshInterval: TimeInterval = 50 * 60
    
    // 后台任务标识符
    private let backgroundTaskIdentifier = "com.follo.ai.tokenRefresh"
    
    private var refreshTimer: Timer?
    private var lastRefreshTime: Date?
    
    private init() {}
    
    // MARK: - 启动 Token 刷新机制
    
    /// 启动自动刷新（在 App 启动时调用）
    func startAutoRefresh() {
        print("🔄 [TokenRefreshManager] Starting auto-refresh mechanism")
        
        // 注册后台任务
        registerBackgroundTask()
        
        // 启动前台定时器
        startForegroundTimer()
        
        // 监听 App 生命周期
        setupNotifications()
        
        // 立即检查一次 Token 是否需要刷新
        Task {
            await checkAndRefreshIfNeeded()
        }
    }
    
    /// 停止自动刷新
    func stopAutoRefresh() {
        print("🛑 [TokenRefreshManager] Stopping auto-refresh")
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: - 前台定时刷新
    
    private func startForegroundTimer() {
        refreshTimer?.invalidate()
        
        // 每 50 分钟刷新一次
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkAndRefreshIfNeeded()
            }
        }
        
        print("⏰ [TokenRefreshManager] Foreground timer started (interval: \(Int(refreshInterval/60)) minutes)")
    }
    
    // MARK: - Token 刷新逻辑
    
    /// 检查并在需要时刷新 Token
    func checkAndRefreshIfNeeded() async {
        guard let accessToken = keychainService.getAccessToken() else {
            print("⚠️ [TokenRefreshManager] No access token found, user not logged in")
            return
        }
        
        // 检查 Token 是否即将过期（解析 JWT 获取过期时间）
        if let expirationDate = getTokenExpirationDate(from: accessToken) {
            let timeUntilExpiration = expirationDate.timeIntervalSinceNow
            
            print("🔍 [TokenRefreshManager] Token expires in \(Int(timeUntilExpiration/60)) minutes")
            
            // 如果 Token 将在 10 分钟内过期，立即刷新
            if timeUntilExpiration < 10 * 60 {
                print("⚠️ [TokenRefreshManager] Token expiring soon, refreshing...")
                await refreshToken()
            } else {
                print("✅ [TokenRefreshManager] Token still valid")
            }
        } else {
            // 无法解析过期时间，尝试刷新
            print("⚠️ [TokenRefreshManager] Cannot parse token expiration, refreshing to be safe...")
            await refreshToken()
        }
    }
    
    /// 刷新 Token
    @discardableResult
    func refreshToken() async -> Bool {
        guard let refreshToken = keychainService.getRefreshToken() else {
            print("❌ [TokenRefreshManager] No refresh token available")
            return false
        }
        
        do {
            print("🔄 [TokenRefreshManager] Refreshing token...")
            let tokenResponse = try await backendService.refreshToken(refreshToken: refreshToken)
            
            // 保存新的 Token
            _ = keychainService.setAccessToken(tokenResponse.access_token)
            _ = keychainService.setRefreshToken(tokenResponse.refresh_token)
            
            lastRefreshTime = Date()
            print("✅ [TokenRefreshManager] Token refreshed successfully at \(lastRefreshTime!)")
            
            return true
        } catch {
            print("❌ [TokenRefreshManager] Token refresh failed: \(error)")
            return false
        }
    }
    
    // MARK: - JWT 解析
    
    /// 从 JWT Token 中提取过期时间
    private func getTokenExpirationDate(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        
        var payload = String(parts[1])
        // Base64 URL 解码需要补齐
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }
        
        return Date(timeIntervalSince1970: exp)
    }
    
    // MARK: - 后台任务
    
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { [weak self] task in
            self?.handleBackgroundTask(task as! BGAppRefreshTask)
        }
    }
    
    private func handleBackgroundTask(_ task: BGAppRefreshTask) {
        print("🔄 [TokenRefreshManager] Background task triggered")
        
        // 安排下一次后台任务
        scheduleBackgroundTask()
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task {
            let success = await refreshToken()
            task.setTaskCompleted(success: success)
        }
    }
    
    func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("📅 [TokenRefreshManager] Background task scheduled for \(request.earliestBeginDate!)")
        } catch {
            print("❌ [TokenRefreshManager] Failed to schedule background task: \(error)")
        }
    }
    
    // MARK: - App 生命周期
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func appWillEnterForeground() {
        print("🌅 [TokenRefreshManager] App entering foreground")
        startForegroundTimer()
        
        // 进入前台时检查 Token
        Task {
            await checkAndRefreshIfNeeded()
        }
    }
    
    @objc private func appDidEnterBackground() {
        print("🌙 [TokenRefreshManager] App entering background")
        refreshTimer?.invalidate()
        refreshTimer = nil
        
        // 安排后台刷新任务
        scheduleBackgroundTask()
    }
    
    // MARK: - 状态查询
    
    /// 获取当前 Token 状态
    func getTokenStatus() -> TokenStatus {
        guard let accessToken = keychainService.getAccessToken() else {
            return TokenStatus(isValid: false, expiresIn: nil, lastRefresh: lastRefreshTime)
        }
        
        let expirationDate = getTokenExpirationDate(from: accessToken)
        let expiresIn = expirationDate?.timeIntervalSinceNow
        
        return TokenStatus(
            isValid: (expiresIn ?? 0) > 0,
            expiresIn: expiresIn,
            lastRefresh: lastRefreshTime
        )
    }
}

// MARK: - Token 状态结构体

struct TokenStatus {
    let isValid: Bool
    let expiresIn: TimeInterval?
    let lastRefresh: Date?
    
    var expiresInMinutes: Int? {
        guard let expiresIn = expiresIn else { return nil }
        return Int(expiresIn / 60)
    }
    
    var statusDescription: String {
        if !isValid {
            return "❌ 无效或已过期"
        }
        if let minutes = expiresInMinutes {
            if minutes < 10 {
                return "⚠️ 即将过期（\(minutes)分钟）"
            } else {
                return "✅ 有效（\(minutes)分钟后过期）"
            }
        }
        return "✅ 有效"
    }
}
