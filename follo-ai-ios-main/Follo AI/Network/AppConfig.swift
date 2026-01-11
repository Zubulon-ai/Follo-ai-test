//
//  AppConfig.swift
//  Follo AI
//
//  DashScope 直连配置读取
//

import Foundation

/// 应用配置管理器 - 从 Info.plist 读取配置
struct AppConfig {
    
    // MARK: - Direct DashScope 开关
    
    /// 是否启用 DashScope 直连模式（绕过后端）
    static var directDashScopeEnabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DirectDashScopeEnabled") as? Bool else {
            // 默认关闭，使用后端模式
            print("⚠️ [AppConfig] DirectDashScopeEnabled 未配置，默认使用后端模式")
            return false
        }
        return value
    }
    
    // MARK: - DashScope 配置
    
    /// DashScope API Key (sk-开头)
    static var dashScopeAPIKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "DashScopeAPIKey") as? String,
              !key.isEmpty,
              key != "sk-YOUR_API_KEY_HERE" else {
            return nil
        }
        return key
    }
    
    /// DashScope Base URL
    static var dashScopeBaseURL: String {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "DashScopeBaseURL") as? String,
              !url.isEmpty else {
            fatalError("❌ [AppConfig] DashScopeBaseURL not found in Info.plist")
        }
        return url
    }
    
    /// DashScope App Completion Path Template (含 {APP_ID} 占位符)
    static var dashScopeAppCompletionPathTemplate: String {
        guard let template = Bundle.main.object(forInfoDictionaryKey: "DashScopeAppCompletionPathTemplate") as? String,
              !template.isEmpty else {
            fatalError("❌ [AppConfig] DashScopeAppCompletionPathTemplate not found in Info.plist")
        }
        return template
    }
    
    /// Agent A AppID
    static var agentAAppId: String {
        guard let appId = Bundle.main.object(forInfoDictionaryKey: "AgentAAppId") as? String,
              !appId.isEmpty else {
            fatalError("❌ [AppConfig] AgentAAppId not found in Info.plist")
        }
        return appId
    }
    
    /// Agent B AppID
    static var agentBAppId: String {
        guard let appId = Bundle.main.object(forInfoDictionaryKey: "AgentBAppId") as? String,
              !appId.isEmpty else {
            fatalError("❌ [AppConfig] AgentBAppId not found in Info.plist")
        }
        return appId
    }
    
    // MARK: - 辅助方法
    
    /// 构建指定 AppID 的完整 API URL
    static func buildAppCompletionURL(appId: String) -> String {
        let path = dashScopeAppCompletionPathTemplate.replacingOccurrences(of: "{APP_ID}", with: appId)
        return dashScopeBaseURL + path
    }
    
    /// 检查 DashScope 直连是否可用（开关开启且有 API Key）
    static var isDirectModeAvailable: Bool {
        return directDashScopeEnabled && dashScopeAPIKey != nil
    }
    
    /// 获取 API Key 的安全显示版本（仅前6位）
    static var maskedAPIKey: String {
        guard let key = dashScopeAPIKey else { return "(未配置)" }
        if key.count <= 6 { return key }
        return String(key.prefix(6)) + "..."
    }
}
