//
//  TriggerDebugView.swift
//  Follo AI
//
//  触发器和 Token 调试视图
//

import SwiftUI

// MARK: - 通用入口（无 iOS 版本限制）
struct DebugPanelView: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            TriggerDebugView()
        } else {
            TriggerDebugViewCompat()
        }
    }
}

@available(iOS 17.0, *)
struct TriggerDebugView: View {
    @StateObject private var triggerManager = TriggerManager.shared
    @State private var tokenStatus: TokenStatus = TokenStatus(isValid: false, expiresIn: nil, lastRefresh: nil)
    @State private var isManualTriggering = false
    @State private var isRefreshingToken = false
    @State private var statusSummary = "加载中..."
    @State private var showDetailedLogs = false
    
    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "ant.circle.fill")
                    .foregroundColor(.orange)
                Text("调试面板")
                    .font(.headline)
                Spacer()
                Button(action: refreshStatus) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
            }
            
            // 触发器状态
            GroupBox(label: Label("触发器状态", systemImage: "location.circle")) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(label: "Monitor", value: triggerManager.isMonitorInitialized ? "✅ 已初始化" : "❌ 未初始化")
                    StatusRow(label: "围栏", value: triggerManager.isTetherActive ? "✅ 已激活" : "❌ 未激活")
                    StatusRow(label: "最后状态", value: triggerManager.lastTriggerStatus)
                }
            }
            
            // Token 状态
            GroupBox(label: Label("Token 状态", systemImage: "key.fill")) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(label: "状态", value: tokenStatus.statusDescription)
                    if let minutes = tokenStatus.expiresInMinutes {
                        StatusRow(label: "过期时间", value: "\(minutes) 分钟后")
                    }
                    if let lastRefresh = tokenStatus.lastRefresh {
                        StatusRow(label: "上次刷新", value: lastRefresh.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
            
            // 操作按钮
            HStack(spacing: 12) {
                Button(action: manualTrigger) {
                    HStack {
                        if isManualTriggering {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("手动触发")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isManualTriggering)
                
                Button(action: refreshToken) {
                    HStack {
                        if isRefreshingToken {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("刷新Token")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(isRefreshingToken)
            }
            
            // 详细状态
            if showDetailedLogs {
                GroupBox(label: Label("详细状态", systemImage: "doc.text")) {
                    Text(statusSummary)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            Button(action: { showDetailedLogs.toggle() }) {
                Text(showDetailedLogs ? "隐藏详情" : "显示详情")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
        .onAppear {
            refreshStatus()
        }
    }
    
    private func refreshStatus() {
        tokenStatus = TokenRefreshManager.shared.getTokenStatus()
        statusSummary = triggerManager.getStatusSummary()
    }
    
    private func manualTrigger() {
        isManualTriggering = true
        triggerManager.manualTrigger()
        
        // 延迟后刷新状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            isManualTriggering = false
            refreshStatus()
        }
    }
    
    private func refreshToken() {
        isRefreshingToken = true
        Task {
            await TokenRefreshManager.shared.refreshToken()
            await MainActor.run {
                isRefreshingToken = false
                refreshStatus()
            }
        }
    }
}

// MARK: - 状态行组件
struct StatusRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - iOS 16 兼容版本
struct TriggerDebugViewCompat: View {
    @State private var tokenStatus: TokenStatus = TokenStatus(isValid: false, expiresIn: nil, lastRefresh: nil)
    @State private var isRefreshingToken = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "ant.circle.fill")
                    .foregroundColor(.orange)
                Text("调试面板 (iOS 16)")
                    .font(.headline)
                Spacer()
            }
            
            GroupBox(label: Label("Token 状态", systemImage: "key.fill")) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(label: "状态", value: tokenStatus.statusDescription)
                    if let minutes = tokenStatus.expiresInMinutes {
                        StatusRow(label: "过期时间", value: "\(minutes) 分钟后")
                    }
                }
            }
            
            Button(action: refreshToken) {
                HStack {
                    if isRefreshingToken {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("刷新Token")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(isRefreshingToken)
            
            Text("注意: 触发器功能需要 iOS 17+")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
        .onAppear {
            refreshStatus()
        }
    }
    
    private func refreshStatus() {
        tokenStatus = TokenRefreshManager.shared.getTokenStatus()
    }
    
    private func refreshToken() {
        isRefreshingToken = true
        Task {
            await TokenRefreshManager.shared.refreshToken()
            await MainActor.run {
                isRefreshingToken = false
                refreshStatus()
            }
        }
    }
}

#Preview {
    DebugPanelView()
}
