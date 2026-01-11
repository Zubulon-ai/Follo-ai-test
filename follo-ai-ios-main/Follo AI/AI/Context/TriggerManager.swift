import Foundation
import CoreLocation
import CoreMotion
import UIKit

@available(iOS 17.0, *)
class TriggerManager: NSObject, ObservableObject {
    static let shared = TriggerManager()
    
    private let monitorName = "FolloMonitor"
    private var monitor: CLMonitor?
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private let backendAPI = BackendAPIService()
    
    // Cooldown
    private let cooldownKey = "lastTriggerTime"
    // private let cooldownDuration: TimeInterval = 20 * 60 // 20 minutes (Production)
    private let cooldownDuration: TimeInterval = 10 // 10 seconds (Testing)
    
    // State
    private var needsTetherUpdate = true
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    
    // Debug: Track initialization status
    @Published var isMonitorInitialized = false
    @Published var isTetherActive = false
    @Published var lastTriggerStatus: String = "未触发"
    
    override init() {
        super.init()
        setupLocationManager()
        Task {
            await setupMonitor()
        }
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100 // Only update if moved 100m
        
        // Request Always Authorization
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        }
        
        // Start monitoring significant location changes to ensure app stays alive
        locationManager.startMonitoringSignificantLocationChanges()
    }
    
    private func setupMonitor() async {
        print("🚀 [TriggerManager] Initializing CLMonitor...")
        monitor = await CLMonitor(monitorName)
        print("✅ [TriggerManager] CLMonitor initialized")
        
        await MainActor.run {
            isMonitorInitialized = true
        }
        
        // 等待获取初始位置（最多等待 5 秒）
        let location = await waitForInitialLocation(timeout: 5.0)
        
        if let loc = location {
            updateDynamicFence(at: loc)
            print("✅ [TriggerManager] Initial tether created at \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
        } else {
            print("⚠️ [TriggerManager] Failed to get initial location, tether NOT created!")
            await MainActor.run {
                lastTriggerStatus = "初始化失败：无法获取位置"
            }
        }
        
        // Start listening for events
        startMonitoring()
    }
    
    /// 等待获取初始位置
    private func waitForInitialLocation(timeout: TimeInterval) async -> CLLocation? {
        // 如果已有位置，直接返回
        if let loc = locationManager.location {
            return loc
        }
        
        // 请求位置并等待
        return await withCheckedContinuation { continuation in
            self.locationContinuation = continuation
            self.locationManager.requestLocation()
            
            // 设置超时
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // 如果还没有返回，超时
                if let cont = self.locationContinuation {
                    self.locationContinuation = nil
                    cont.resume(returning: self.locationManager.location)
                }
            }
        }
    }
    
    // MARK: - Debug / Manual Test
    
    /// 手动触发一次 context 收集（用于测试）
    func manualTrigger() {
        print("🧪 [TriggerManager] Manual trigger initiated!")
        Task {
            // 跳过冷却检查，直接执行上传
            await forceUploadContext()
        }
    }
    
    /// 强制上传 context（跳过冷却）
    private func forceUploadContext() async {
        await MainActor.run {
            lastTriggerStatus = "手动触发中..."
        }
        
        guard let token = KeychainService.shared.getAccessToken(), !token.isEmpty else {
            print("❌ [TriggerManager] No auth token! User not logged in.")
            await MainActor.run {
                lastTriggerStatus = "失败: 用户未登录"
            }
            return
        }
        
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(taskId)
        }
        
        let snapshot = await ContextCollector.shared.collectContextSnapshot()
        print("📤 [TriggerManager] Manual upload - Snapshot: time=\(snapshot.current_time), activity=\(snapshot.activity)")
        
        do {
            let response = try await backendAPI.uploadContextSnapshot(trigger: "MANUAL_TEST", snapshot: snapshot)
            print("✅ [TriggerManager] Manual upload success! Decision: \(response.decision)")
            await MainActor.run {
                lastTriggerStatus = "手动测试成功: \(response.decision)"
            }
        } catch {
            print("❌ [TriggerManager] Manual upload failed: \(error)")
            await MainActor.run {
                lastTriggerStatus = "手动测试失败: \(error.localizedDescription)"
            }
        }
        
        UIApplication.shared.endBackgroundTask(taskId)
    }
    
    /// 获取当前状态摘要
    func getStatusSummary() -> String {
        let hasToken = KeychainService.shared.getAccessToken() != nil
        let hasLocation = locationManager.location != nil
        let authStatus = locationManager.authorizationStatus
        
        return """
        Monitor初始化: \(isMonitorInitialized ? "✅" : "❌")
        围栏激活: \(isTetherActive ? "✅" : "❌")
        用户Token: \(hasToken ? "✅" : "❌ 未登录")
        位置可用: \(hasLocation ? "✅" : "❌")
        位置权限: \(authStatus == .authorizedAlways ? "✅ 始终" : (authStatus == .authorizedWhenInUse ? "⚠️ 仅使用时" : "❌ 无权限"))
        最后状态: \(lastTriggerStatus)
        """
    }
    
    // MARK: - Dynamic Geofence (Virtual Tether)
    
    func updateDynamicFence(at location: CLLocation) {
        Task {
            guard let monitor = monitor else { 
                print("❌ [TriggerManager] Monitor is nil, cannot create fence!")
                return 
            }
            
            // Remove old dynamic fence
            await monitor.remove("DynamicTether")
            
            // Create new fence: 150m radius, notify on exit
            let condition = CLMonitor.CircularGeographicCondition(
                center: location.coordinate,
                radius: 150
            )
            
            await monitor.add(condition, identifier: "DynamicTether", assuming: .satisfied)
            print("📍 [TriggerManager] Updated Dynamic Tether at \(location.coordinate.latitude), \(location.coordinate.longitude) (Radius: 150m)")
            
            await MainActor.run {
                isTetherActive = true
            }
        }
    }
    
    // MARK: - Semantic Geofences
    
    func updateSemanticFences(locations: [(id: String, coordinate: CLLocationCoordinate2D, radius: CLLocationDistance)]) {
        Task {
            guard let monitor = monitor else { return }
            
            // Clear old semantic fences (except DynamicTether)
            for identifier in await monitor.identifiers {
                if identifier != "DynamicTether" {
                    await monitor.remove(identifier)
                }
            }
            
            // Add new ones
            for loc in locations {
                let condition = CLMonitor.CircularGeographicCondition(
                    center: loc.coordinate,
                    radius: loc.radius
                )
                await monitor.add(condition, identifier: loc.id, assuming: .unknown)
            }
        }
    }
    
    // MARK: - Event Handling
    
    func handleWakeUp() async {
        let wakeUpTime = Date()
        print("🔔 [TriggerManager] App Woken Up by Trigger at \(wakeUpTime)")
        
        await MainActor.run {
            lastTriggerStatus = "触发中... \(wakeUpTime.formatted(date: .omitted, time: .shortened))"
        }
        
        // 0. 检查用户是否已登录
        guard let token = KeychainService.shared.getAccessToken(), !token.isEmpty else {
            print("❌ [TriggerManager] No auth token! User not logged in. Skipping upload.")
            await MainActor.run {
                lastTriggerStatus = "跳过：用户未登录"
            }
            // 仍然需要更新围栏以保持链条
            needsTetherUpdate = true
            if let loc = locationManager.location {
                updateDynamicFence(at: loc)
                needsTetherUpdate = false
            }
            return
        }
        
        // 1. Check Cooldown
        let lastTime = UserDefaults.standard.double(forKey: cooldownKey)
        let now = wakeUpTime.timeIntervalSince1970
        let elapsed = now - lastTime
        
        if elapsed < cooldownDuration {
            let remaining = Int(cooldownDuration - elapsed)
            print("⏳ [TriggerManager] Cooldown active. Elapsed: \(Int(elapsed))s, Remaining: \(remaining)s. Skipping API call.")
            await MainActor.run {
                lastTriggerStatus = "冷却中（剩余 \(remaining)秒）"
            }
            // Even in cooldown, we MUST update the tether to keep the chain alive
            needsTetherUpdate = true
            if let loc = locationManager.location {
                updateDynamicFence(at: loc)
                needsTetherUpdate = false
            } else {
                print("⚠️ [TriggerManager] No location available during cooldown wake-up, requesting location...")
                locationManager.requestLocation() // Will trigger delegate update
            }
            return
        }
        
        print("✅ [TriggerManager] Cooldown passed. Proceeding with Context Collection...")
        
        // 2. Start Background Task
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask {
            print("⚠️ [TriggerManager] Background task expiring!")
            UIApplication.shared.endBackgroundTask(taskId)
        }
        
        // 3. Collect Context & Upload
        let triggerType = "MOTION_CHANGE" // Default fallback
        
        // Collect
        print("📊 [TriggerManager] Collecting Context Snapshot...")
        let snapshot = await ContextCollector.shared.collectContextSnapshot()
        print("📤 [TriggerManager] Uploading Snapshot to Backend...")
        print("📤 [TriggerManager] Snapshot: time=\(snapshot.current_time), activity=\(snapshot.activity), location=\(snapshot.location_semantic ?? "nil")")
        
        // Upload
        do {
            let response = try await backendAPI.uploadContextSnapshot(trigger: triggerType, snapshot: snapshot)
            print("✅ [TriggerManager] Upload success! Decision: \(response.decision)")
            await MainActor.run {
                lastTriggerStatus = "成功: \(response.decision) @ \(wakeUpTime.formatted(date: .omitted, time: .shortened))"
            }
            if let notif = response.notification {
                print("📩 [TriggerManager] Notification received: \(notif.title)")
            }
        } catch let error as BackendAPIError {
            print("❌ [TriggerManager] Upload failed: \(error)")
            await MainActor.run {
                switch error {
                case .unauthorized:
                    lastTriggerStatus = "失败: 未授权(401) - Token可能过期"
                case .httpError(let code):
                    lastTriggerStatus = "失败: HTTP \(code)"
                default:
                    lastTriggerStatus = "失败: \(error.localizedDescription)"
                }
            }
            
            // 如果是 401，尝试刷新 Token
            if case .unauthorized = error {
                print("🔄 [TriggerManager] Attempting to refresh token...")
                await attemptTokenRefresh()
            }
        } catch {
            print("❌ [TriggerManager] Upload failed with unknown error: \(error)")
            await MainActor.run {
                lastTriggerStatus = "失败: \(error.localizedDescription)"
            }
        }
        
        // Update Cooldown
        UserDefaults.standard.set(now, forKey: cooldownKey)
        print("⏱️ [TriggerManager] Cooldown reset. Next trigger allowed after \(Int(cooldownDuration))s.")
        
        // 4. Update Tether
        needsTetherUpdate = true
        if let loc = locationManager.location {
            updateDynamicFence(at: loc)
            needsTetherUpdate = false
        } else {
             print("⚠️ [TriggerManager] No location available after upload, requesting location for tether update...")
             locationManager.requestLocation()
        }
        
        print("🏁 [TriggerManager] Wake-up handling complete.")
        UIApplication.shared.endBackgroundTask(taskId)
    }
    
    /// 尝试刷新 Token
    private func attemptTokenRefresh() async {
        guard let refreshToken = KeychainService.shared.getRefreshToken() else {
            print("❌ [TriggerManager] No refresh token available")
            return
        }
        
        do {
            let tokenResponse = try await backendAPI.refreshToken(refreshToken: refreshToken)
            _ = KeychainService.shared.setAccessToken(tokenResponse.access_token)
            _ = KeychainService.shared.setRefreshToken(tokenResponse.refresh_token)
            print("✅ [TriggerManager] Token refreshed successfully!")
        } catch {
            print("❌ [TriggerManager] Token refresh failed: \(error)")
        }
    }
    
    // MARK: - Monitor Loop
    
    func startMonitoring() {
        print("👀 [TriggerManager] Starting Monitor Loop...")
        Task {
            guard let monitor = monitor else {
                print("❌ [TriggerManager] Monitor not initialized!")
                return
            }
            
            // Check current state of all conditions immediately
            for identifier in await monitor.identifiers {
                let record = await monitor.record(for: identifier)
                print("🔍 [TriggerManager] Initial State for \(identifier): \(String(describing: record?.lastEvent.state))")
            }
            
            for try await event in await monitor.events {
                print("🔔 [TriggerManager] Monitor Event Received: \(event.identifier) -> \(event.state)")
                
                if event.identifier == "DynamicTether" && event.state == .unsatisfied {
                    print("🏃 [TriggerManager] Exited Dynamic Tether! Triggering Wake Up...")
                    // Exited the tether
                    await handleWakeUp()
                } else if event.identifier != "DynamicTether" && (event.state == .satisfied || event.state == .unsatisfied) {
                    print("📍 [TriggerManager] Semantic Place Event: \(event.identifier) -> \(event.state)")
                    // Entered or Exited a semantic place
                    await handleWakeUp()
                }
            }
        }
    }
}

extension TriggerManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        print("📍 [TriggerManager] Location Updated: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
        
        // 如果有等待中的 continuation，返回位置
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(returning: loc)
            return
        }
        
        // Only update tether if explicitly requested (e.g. initial setup or after wake-up)
        if needsTetherUpdate {
            updateDynamicFence(at: loc)
            needsTetherUpdate = false
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ [TriggerManager] Location Error: \(error)")
        
        // 如果有等待中的 continuation，返回 nil
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(returning: nil)
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("📍 [TriggerManager] Authorization changed: \(status.rawValue)")
        
        switch status {
        case .authorizedAlways:
            print("✅ [TriggerManager] Always authorization granted!")
        case .authorizedWhenInUse:
            print("⚠️ [TriggerManager] Only 'When In Use' authorization - background triggers may not work!")
        case .denied, .restricted:
            print("❌ [TriggerManager] Location access denied - triggers will not work!")
        case .notDetermined:
            print("⏳ [TriggerManager] Authorization not determined yet")
        @unknown default:
            break
        }
    }
}
