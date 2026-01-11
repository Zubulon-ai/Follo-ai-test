//
//  DataManager.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/8/13.
//

import Foundation
import CoreMotion
import CoreLocation
import AVFoundation
import Network
import SystemConfiguration.CaptiveNetwork
import UIKit
import MapKit

class DataManager: NSObject, ObservableObject {
    // 共享单例，确保各页面使用同一份采集数据
    static let shared = DataManager()
    // MARK: - Properties
    private let motionActivityManager = CMMotionActivityManager()
    private let locationManager = CLLocationManager()

    // Public access to locationManager for ContextCollector
    public var locationManagerInstance: CLLocationManager {
        return locationManager
    }
    private let locationService = LocationService()
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var timer: Timer?
    private var recordingCompletion: ((String) -> Void)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskTimer: Timer? // 管理后台任务刷新的定时器
    
    // Data storage
    private var collectedData: [String] = []
    private let fileName = "harvest_data.txt"
    private var hasBackgroundObserver = false // 防止重复添加通知观察者
    
    override init() {
        self.inputNode = audioEngine.inputNode
        super.init()
        setupLocationManager()
    }
    
    // MARK: - Setup
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        // Don't set allowsBackgroundLocationUpdates here - do it after getting permission
    }
    
    // MARK: - Permissions
    func requestPermissions() {
        // Location permission - request "always" for background operation
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        
        // Microphone permission
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                if granted {
                    print("麦克风权限已授予")
                } else {
                    print("麦克风权限被拒绝")
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if granted {
                    print("麦克风权限已授予")
                } else {
                    print("麦克风权限被拒绝")
                }
            }
        }
        
        // Motion activity permission is handled automatically when first accessed
    }
    
    // MARK: - Recording
    func startRecording(completion: @escaping (String) -> Void) {
        self.recordingCompletion = completion
        
        // Start location updates first (this is the primary background mode)
        locationManager.startUpdatingLocation()
        
        // Start audio monitoring
        startAudioMonitoring()
        
        // Start timer for periodic data collection
        // 采样间隔调至 1s，更容易捕获环境变化
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.collectAllData()
        }
        
        // Start background task as backup (will auto-refresh to avoid warnings)
        // Only needed when app goes to background
        if UIApplication.shared.applicationState != .active {
            startBackgroundTask()
        } else if !hasBackgroundObserver {
            // Monitor app state changes - only add once
            hasBackgroundObserver = true
            
            // 监听进入后台事件
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if self.timer != nil {
                    self.startBackgroundTask()
                }
            }
            
            // 监听回到前台事件
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                if self.timer != nil {
                    print("应用回到前台，停止后台任务以节省资源")
                    self.endBackgroundTask()
                }
            }
        }
        
        print("开始记录数据...")
    }
    
    func stopRecording() {
        timer?.invalidate()
        timer = nil
        
        // Also invalidate background task timer
        backgroundTaskTimer?.invalidate()
        backgroundTaskTimer = nil
        
        locationManager.stopUpdatingLocation()
        stopAudioMonitoring()
        recordingCompletion = nil
        
        // Remove notification observers
        if hasBackgroundObserver {
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )
            hasBackgroundObserver = false
        }
        
        // Disable background location updates
        disableBackgroundLocationUpdates()
        
        // Save all data to file
        saveDataToFile()
        
        // End background task
        endBackgroundTask()
        
        print("停止记录数据")
    }
    
    // MARK: - Data Collection
    private func collectAllData() {
        let timestamp = TimeZoneManager.shared.formatDateWithTimeZone(Date())
        let baseDataString = "时间: \(timestamp)\n"
        
        // Collect Motion Activity
        collectMotionActivity { motionData in
            let motionDataString = baseDataString + "运动状态: \(motionData)\n"
            
            // Collect GPS and Location Info
            if let location = self.locationManager.location {
                // 异步获取完整的地理位置描述（仅地址信息）
                Task {
                    let locationDescription = await self.locationService.getFullLocationDescription(for: location)
                    
                    DispatchQueue.main.async {
                        var updatedDataString = motionDataString
                        updatedDataString += "地理位置: \(locationDescription)\n"
                        
                        // Collect WiFi info
                        let wifiInfo = self.getWiFiInfo()
                        updatedDataString += "WiFi: \(wifiInfo)\n"
                        
                        // Collect audio level (will be updated by audio monitoring)
                        updatedDataString += "声音分贝: \(self.getCurrentAudioLevel()) dB\n"
                        
                        updatedDataString += "---\n"
                        
                        self.collectedData.append(updatedDataString)
                        self.recordingCompletion?(updatedDataString)
                    }
                }
            } else {
                var finalDataString = motionDataString
                finalDataString += "地理位置: 位置信息不可用\n"
                
                // Collect WiFi info
                let wifiInfo = self.getWiFiInfo()
                finalDataString += "WiFi: \(wifiInfo)\n"
                
                // Collect audio level (will be updated by audio monitoring)
                finalDataString += "声音分贝: \(self.getCurrentAudioLevel()) dB\n"
                
                finalDataString += "---\n"
                
                self.collectedData.append(finalDataString)
                self.recordingCompletion?(finalDataString)
            }
        }
    }
    
    public func getMotionActivity() async -> String {
        return await withCheckedContinuation { continuation in
            collectMotionActivity { activity in
                continuation.resume(returning: activity)
            }
        }
    }

    private func collectMotionActivity(completion: @escaping (String) -> Void) {
        if CMMotionActivityManager.isActivityAvailable() {
            let queue = OperationQueue()
            
            // 设置超时，避免永久等待
            let timeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                self.motionActivityManager.stopActivityUpdates()
                // 如果实时检测超时，尝试查询历史数据
                self.queryRecentActivity(completion: completion)
            }
            
            motionActivityManager.startActivityUpdates(to: queue) { activity in
                guard let activity = activity else {
                    timeoutTimer.invalidate()
                    // 如果没有活动数据，尝试查询历史数据
                    self.queryRecentActivity(completion: completion)
                    return
                }
                
                // 停止超时计时器
                timeoutTimer.invalidate()
                
                var activities: [String] = []
                var confidenceInfo = ""
                
                // 检查置信度
                switch activity.confidence {
                case .low:
                    confidenceInfo = "(置信度:低)"
                case .medium:
                    confidenceInfo = "(置信度:中)"
                case .high:
                    confidenceInfo = "(置信度:高)"
                @unknown default:
                    confidenceInfo = "(置信度:未知)"
                }
                
                // 收集所有活动状态
                if activity.walking { 
                    activities.append("走路") 
                }
                if activity.running { 
                    activities.append("跑步") 
                }
                if activity.automotive { 
                    activities.append("驾驶") 
                }
                if activity.cycling { 
                    activities.append("骑行") 
                }
                if activity.stationary { 
                    activities.append("静止") 
                }
                if activity.unknown { 
                    activities.append("未知") 
                }
                
                let result: String
                if activities.isEmpty {
                    result = "无明确活动\(confidenceInfo)"
                } else {
                    result = "\(activities.joined(separator: ", "))\(confidenceInfo)"
                }
                
                completion(result)
                
                // Stop after getting one reading
                self.motionActivityManager.stopActivityUpdates()
            }
        } else {
            completion("运动检测不可用")
        }
    }
    
    // 查询最近的活动历史
    private func queryRecentActivity(completion: @escaping (String) -> Void) {
        let now = Date()
        let fiveMinutesAgo = now.addingTimeInterval(-300) // 5分钟前
        
        motionActivityManager.queryActivityStarting(from: fiveMinutesAgo, to: now, to: OperationQueue()) { activities, error in
            if let error = error {
                completion("历史查询失败: \(error.localizedDescription)")
                return
            }
            
            guard let activities = activities, !activities.isEmpty else {
                completion("无历史活动数据")
                return
            }
            
            // 获取最近的活动
            if let lastActivity = activities.last {
                var activityTypes: [String] = []
                if lastActivity.walking { activityTypes.append("走路") }
                if lastActivity.running { activityTypes.append("跑步") }
                if lastActivity.automotive { activityTypes.append("驾驶") }
                if lastActivity.cycling { activityTypes.append("骑行") }
                if lastActivity.stationary { activityTypes.append("静止") }
                if lastActivity.unknown { activityTypes.append("未知") }
                
                let confidenceText: String
                switch lastActivity.confidence {
                case .low: confidenceText = "低"
                case .medium: confidenceText = "中"
                case .high: confidenceText = "高"
                @unknown default: confidenceText = "未知"
                }
                
                let result = activityTypes.isEmpty ? 
                    "最近无明确活动(置信度:\(confidenceText))" : 
                    "最近:\(activityTypes.joined(separator: ", "))(置信度:\(confidenceText))"
                completion(result)
            } else {
                completion("无最近活动记录")
            }
        }
    }
    
    private func getWiFiInfo() -> String {
        // 需求：自动收集时不再采集网络连接状态，此方法仅供旧逻辑兼容
        return "(已停用: 网络状态不再采集)"
    }
    
    // MARK: - Audio Monitoring
    private var currentAudioLevel: Float = -80.0
    
    private func startAudioMonitoring() {
        // Check if running on simulator - audio recording may not work properly
        #if targetEnvironment(simulator)
        print("在模拟器上运行，跳过音频监测")
        return
        #else
        // Check microphone permission first
        let hasPermission: Bool
        if #available(iOS 17.0, *) {
            hasPermission = AVAudioApplication.shared.recordPermission == .granted
        } else {
            hasPermission = AVAudioSession.sharedInstance().recordPermission == .granted
        }
        
        guard hasPermission else {
            print("麦克风权限未授予，跳过音频监测")
            return
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Make sure the audio engine is stopped before reconfiguring
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            
            // Remove any existing taps
            inputNode.removeTap(onBus: 0)
            
            // Try using hardware format first, fallback to automatic format selection
            let hardwareFormat = inputNode.inputFormat(forBus: 0)
            print("硬件音频格式: 采样率=\(hardwareFormat.sampleRate), 声道数=\(hardwareFormat.channelCount)")
            
            // Install tap with format validation
            if hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
                    self.processAudioBuffer(buffer)
                }
                print("使用硬件格式安装音频tap")
            } else {
                // Fallback: let the system choose the format automatically
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    self.processAudioBuffer(buffer)
                }
                print("使用自动格式安装音频tap")
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            logCurrentAudioRoute()
            print("音频引擎启动成功")
        } catch {
            print("音频引擎启动失败: \(error)")
        }
        #endif
    }
    
    private func stopAudioMonitoring() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        // Safely remove tap
        inputNode.removeTap(onBus: 0)
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("音频会话停止失败: \(error)")
        }
        
        print("音频监测已停止")
    }

    // MARK: - Public wrappers for ambient monitoring
    func ensureAudioMonitoringStarted() {
        #if targetEnvironment(simulator)
        print("模拟器环境，跳过音频监测启动")
        #else
        startAudioMonitoring()
        #endif
    }

    func ensureAudioMonitoringStopped() {
        #if targetEnvironment(simulator)
        #else
        stopAudioMonitoring()
        #endif
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        let channelDataArray = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        
        // 以 dBFS 计算（PCM 归一化振幅相对满刻度），范围约 [-80, 0]
        let rms = sqrt(channelDataArray.map { $0 * $0 }.reduce(0, +) / max(1, Float(channelDataArray.count)))
        let epsilon: Float = 1e-9
        let safeRms = max(epsilon, rms)
        var dbfs = 20 * log10(safeRms)
        if dbfs.isNaN || dbfs.isInfinite { dbfs = -80.0 }
        currentAudioLevel = max(-80.0, min(0.0, dbfs))
    }

    private func logCurrentAudioRoute() {
        let s = AVAudioSession.sharedInstance()
        let inPorts = s.currentRoute.inputs.map { $0.portType.rawValue + ":" + $0.portName }.joined(separator: ", ")
        let outPorts = s.currentRoute.outputs.map { $0.portType.rawValue + ":" + $0.portName }.joined(separator: ", ")
        print("[AudioRoute] category=\(s.category.rawValue), mode=\(s.mode.rawValue), inputs=[\(inPorts)], outputs=[\(outPorts)]")
    }
    
    func getCurrentAudioLevel() -> String {
        #if targetEnvironment(simulator)
        return "模拟器(无音频)"
        #else
        // 将内部 dBFS [-80, 0] 映射为 [0, 80] 的正值显示，便于理解
        let mapped = max(0.0, min(80.0, 80.0 + Double(currentAudioLevel)))
        return String(format: "%.1f", mapped)
        #endif
    }
    
    // MARK: - File Management
    private func saveDataToFile() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        let dataText = collectedData.joined(separator: "\n")
        
        do {
            try dataText.write(to: fileURL, atomically: true, encoding: .utf8)
            print("数据已保存到: \(fileURL.path)")
        } catch {
            print("保存文件失败: \(error)")
        }
    }
    
    func getDataFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(fileName)
    }
    
    // 获取最新的3条状态数据
    func getLatest3StatusData() -> [String] {
        return Array(collectedData.suffix(3))
    }

    // 获取最新的3条状态数据（包含持久化回退）
    func getLatest3StatusDataIncludingPersisted() -> [String] {
        let inMemory = Array(collectedData.suffix(3))
        if !inMemory.isEmpty { return inMemory }

        // 回退读取文件
        let fileURL = getDataFileURL()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        // 根据分隔符"---\n"拆分记录块
        let rawParts = text.components(separatedBy: "\n---\n")
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
        let last = Array(parts.suffix(3))
        // 恢复每段的结尾分隔符格式，保持与内存记录一致
        return last.map { $0 + "\n---\n" }
    }

    // MARK: - 新增：应用启动时自动采集1次（排除网络状态）
    // 每次调用进行1次采集，采集内容与 collectAllData 基本一致，但会跳过 WiFi/网络信息
    func autoCollectThreeTimesExcludeNetwork(progress: @escaping (Int) -> Void) async {
        // 确保已申请权限
        await MainActor.run { self.requestPermissions() }
        // 轻量位置一次
        locationManager.startUpdatingLocation()
        defer { locationManager.stopUpdatingLocation() }
        // 启动环境音监测（若未启动）
        ensureAudioMonitoringStarted()
        defer { ensureAudioMonitoringStopped() }
        // 等待音频引擎稳定
        try? await Task.sleep(nanoseconds: 150_000_000)

        // 只采集1次（之前是3次）
        let timestamp = TimeZoneManager.shared.formatDateWithTimeZone(Date())
        let base = "时间: \(timestamp)\n"
        collectMotionActivity { motionData in
            let motionString = base + "运动状态: \(motionData)\n"
            if let loc = self.locationManager.location {
                Task {
                    let addr = await self.locationService.getFullLocationDescription(for: loc)
                    DispatchQueue.main.async {
                        var s = motionString
                        s += "地理位置: \(addr)\n"
                        // 跳过网络状态
                        s += "声音分贝: \(self.getCurrentAudioLevel()) dB\n"
                        s += "---\n"
                        self.collectedData.append(s)
                        progress(1)
                    }
                }
            } else {
                var s = motionString
                s += "地理位置: 位置信息不可用\n"
                s += "声音分贝: \(self.getCurrentAudioLevel()) dB\n"
                s += "---\n"
                self.collectedData.append(s)
                progress(1)
            }
        }
        
        // 完成后落盘
        saveDataToFile()
    }
    
    // MARK: - Background Task Management
    private func startBackgroundTask() {
        endBackgroundTask() // End any existing background task first
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DataRecording") {
            // Expiration handler - called when task is about to expire
            print("后台任务即将到期，保存数据...")
            self.saveDataToFile()
            self.endBackgroundTask()
            
            // Restart background task if still recording and have location permission
            if self.timer != nil && self.locationManager.authorizationStatus == .authorizedAlways {
                self.startBackgroundTask()
            }
        }
        
        if backgroundTask != .invalid {
            print("后台任务已启动: ID=\(backgroundTask), 剩余时间: \(UIApplication.shared.backgroundTimeRemaining)秒")
            
            // Cancel any existing refresh timer
            backgroundTaskTimer?.invalidate()
            
            // Start a single refresh timer for this task
            backgroundTaskTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
                if self.backgroundTask != .invalid && self.timer != nil {
                    print("刷新后台任务以避免超时...")
                    self.startBackgroundTask() // This will cancel current task and start new one
                }
            }
        } else {
            print("后台任务启动失败")
        }
    }
    
    private func endBackgroundTask() {
        // Cancel refresh timer
        backgroundTaskTimer?.invalidate()
        backgroundTaskTimer = nil
        
        // End background task
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
            print("后台任务已结束")
        }
    }
    
    // MARK: - Background Location Management
    private func enableBackgroundLocationUpdates() {
        // Multiple safety checks
        guard CLLocationManager.locationServicesEnabled() else {
            print("位置服务未启用")
            return
        }
        
        guard locationManager.authorizationStatus == .authorizedAlways else {
            print("无法启用后台位置更新：当前权限状态 \(locationManager.authorizationStatus.rawValue)")
            return
        }
        
        // Check if background location capability is available
        guard Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil else {
            print("应用未配置后台模式权限")
            return
        }
        
        // Only set if not already enabled
        guard !locationManager.allowsBackgroundLocationUpdates else {
            print("后台位置更新已经启用")
            return
        }
        
        locationManager.allowsBackgroundLocationUpdates = true
        print("后台位置更新已启用")
    }
    
    private func disableBackgroundLocationUpdates() {
        if locationManager.allowsBackgroundLocationUpdates {
            locationManager.allowsBackgroundLocationUpdates = false
            print("后台位置更新已禁用")
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension DataManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Location updates are handled in collectAllData()
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("位置更新失败: \(error)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse:
            print("位置权限已授予(使用时)")
            // Request always authorization for background operation
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            print("位置权限已授予(始终)")
            // Safely enable background location updates on main thread with delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.enableBackgroundLocationUpdates()
            }
        case .denied, .restricted:
            print("位置权限被拒绝")
            DispatchQueue.main.async {
                self.disableBackgroundLocationUpdates()
            }
        case .notDetermined:
            print("位置权限未确定")
        @unknown default:
            print("未知的位置权限状态")
        }
    }
} 
