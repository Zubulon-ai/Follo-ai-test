//
//  ContextCollector.swift
//  Follo AI
//
//  用户Context信息收集器
//  收集21个signal并输出为sensor_and_environment_json格式
//

import Foundation
import CoreLocation
import CoreMotion
import Network
import MapKit
import HealthKit

public struct ContextSnapshot: Codable {
    public let current_time: String
    public let current_date: String
    public let activity: String
    public let location_semantic: String?
    public let wifi_ssid: String?
    public let audio_db: Double?
    public let health_steps_today: Int?
    public let device_battery: Double
}

// Signal描述结构体
public struct SignalDescription: Encodable {
    public let signal: String
    public let desc: String
    public let value: Any

    public init(signal: String, desc: String, value: Any) {
        self.signal = signal
        self.desc = desc
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case signal, desc, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signal, forKey: .signal)
        try container.encode(desc, forKey: .desc)

        // 处理value为Any类型
        if let v = value as? String {
            try container.encode(v, forKey: .value)
        } else if let v = value as? Int {
            try container.encode(v, forKey: .value)
        } else if let v = value as? Bool {
            try container.encode(v, forKey: .value)
        } else if let v = value as? Double {
            try container.encode(v, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

public class ContextCollector {
    public static let shared = ContextCollector()

    // 复用现有组件
    private let dataManager = DataManager.shared
    private let timeZoneManager = TimeZoneManager.shared
    private let locationService = LocationService()

    // 新增服务
    private let weatherService = WeatherService()
    private let trafficService = TrafficService()
    private let scheduleAnalyzer = ScheduleAnalyzer()
    private let healthStore = HKHealthStore()

    private init() {
        // 位置和运动活动权限由DataManager统一管理
    }

    // MARK: - Public API

    /// 按需收集context信息
    /// - Parameter event: 可选的事件信息，用于收集事件相关signal
    /// - Returns: [SignalDescription] 格式的信号描述数组
    public func collectContext(for event: Event? = nil) async -> [SignalDescription] {
        var signals: [String: Any] = [:]
        
        // 0. 先请求必要权限
        print("    [Context] 请求权限...")
        dataManager.requestPermissions()
        timeZoneManager.requestLocationPermission()
        await scheduleAnalyzer.requestCalendarPermission()

        // 等待位置权限和位置信息 (最多等待2秒)
        print("    [Context] 等待位置权限和位置信息...")
        var locationWaitCount = 0
        while dataManager.locationManagerInstance.location == nil && locationWaitCount < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            locationWaitCount += 1
        }
        print("    [Context] 位置权限检查完成: \(dataManager.locationManagerInstance.location != nil ? "已获得位置" : "未获得位置")")

        // 1. 时间日程 (同步)
        print("    [Context] 收集时间日程信号...")
        let timeContext = self.collectTimeSignals(for: event)
        signals.merge(timeContext) { _, new in new }

        // 2. 位置信息 (异步)
        print("    [Context] 收集位置信号...")
        let locationContext = await self.collectLocationSignals(for: event)
        signals.merge(locationContext) { _, new in new }

        // 3. 用户活动 (异步)
        print("    [Context] 收集用户活动信号...")
        let activity = await self.dataManager.getMotionActivity()
        signals["har.user_activity"] = activity

        // 4. 网络类型 (同步)
        print("    [Context] 收集网络信号...")
        let networkType = self.getNetworkType() ?? "unavailable"
        signals["network.type"] = networkType
        print("    [Context] 网络类型: \(networkType)")

        // 5. 设备状态 (同步)
        signals["device.battery_level"] = self.getBatteryLevel()

        // 6. 健康数据 (异步)
        print("    [Context] 收集健康数据...")
        let steps = await self.getTodaySteps()
        signals["health.steps_today"] = steps

        // 7. 环境声音 (同步，使用现有DataManager)
        let audioInfo = self.getCurrentAudioInfo()
        signals["environment.sound_level_db"] = audioInfo.level
        signals["environment.sound_type"] = audioInfo.type

        // 7. 外部信息 (异步)
        if let event = event {
            print("    [Context] 收集外部信号...")
            let externalContext = await self.collectExternalSignals(for: event)
            signals.merge(externalContext) { _, new in new }
        } else {
            // 即使没有事件，也尝试收集一些基础外部信息
            print("    [Context] 收集基础外部信号...")
            // 创建虚拟事件用于收集天气（当前时间+当前位置）
            if self.dataManager.locationManagerInstance.location != nil {
                let dummyEvent = Event(
                    title: "current",
                    startDate: Date(),
                    endDate: Date().addingTimeInterval(3600),
                    location: "current_location",
                    isAllDay: false
                )
                let externalContext = await self.collectExternalSignals(for: dummyEvent)
                signals.merge(externalContext) { _, new in new }
            } else {
                // 没有位置，标记为unknown
                signals["weather.forecast_at_event"] = "unknown"
                signals["traffic.eta_to_event"] = -1
                signals["traffic.condition"] = "unknown"
            }
        }

        print("    [Context] 所有信号收集完成，共 \(signals.count) 个")

        // 转换为SignalDescription数组
        return convertToSignalDescriptions(signals)
    }

    public func collectContextSnapshot() async -> ContextSnapshot {
        // 1. Time
        let now = Date()
        let fmtTime = DateFormatter(); fmtTime.dateFormat = "HH:mm"
        let fmtDate = DateFormatter(); fmtDate.dateFormat = "yyyy-MM-dd"
        
        // 2. Activity
        let activity = await dataManager.getMotionActivity()
        
        // 3. Location
        var locSemantic: String? = nil
        if let loc = dataManager.locationManagerInstance.location {
            locSemantic = await locationService.getFullLocationDescription(for: loc)
        }
        
        // 4. Network
        let wifi_ssid: String? = nil 
        
        // 5. Audio
        let audioInfo = self.getCurrentAudioInfo()
        let db = Double(audioInfo.level.replacingOccurrences(of: " dB", with: ""))
        
        // 6. Health
        let steps = await getTodaySteps()
        
        // 7. Battery
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = Double(UIDevice.current.batteryLevel)
        
        return ContextSnapshot(
            current_time: fmtTime.string(from: now),
            current_date: fmtDate.string(from: now),
            activity: activity,
            location_semantic: locSemantic,
            wifi_ssid: wifi_ssid,
            audio_db: db,
            health_steps_today: steps,
            device_battery: battery
        )
    }

    private func convertToSignalDescriptions(_ signals: [String: Any]) -> [SignalDescription] {
        let signalDescriptions: [(String, String)] = [
            // 时间 & 日程
            ("time.current", "当前的精确时刻"),
            ("date.current", "当前的日期和星期"),
            ("time.event_start", "目标事件的开始时间"),
            ("time.event_end", "目标事件的结束时间"),
            ("calendar.current_event", "当前正在进行的日程"),
            ("calendar.next_event", "最近两天下一个日程的内容和时间"),
            ("calendar.prev_event", "最近两天上一个日程的内容和时间"),
            ("calendar.gap_after_event", "当前事件后的日历空隙时长"),
            ("calendar.full_day_load", "用户整日的日程负荷水平 (低/中/高/极高)"),

            // 物理 & 环境
            ("location.user_current_latlon", "用户当前的地理坐标"),
            ("location.user_current_semantic", "用户当前的语义位置 (家/公司/机场/健身房)"),
            ("location.event_latlon", "事件的目标地理坐标"),
            ("location.event_semantic", "事件的目标语义位置"),
            ("location.is_at_home", "布尔值，是否在家"),
            ("location.is_at_work", "布尔值，是否在公司"),
            ("har.user_activity", "用户当前的物理活动 (静坐/走路/跑步/驾驶/睡眠)"),
            ("environment.sound_level_db", "所处环境的噪音分贝"),
            ("environment.sound_type", "所处环境的声音类型 (人声/音乐/交通)"),

            // 外部 & 状态
            ("weather.forecast_at_event", "事件发生时/地的天气预报 (晴/雨/雷暴)"),
            ("traffic.eta_to_event", "从当前位置到事件地点的实时ETA (分钟)"),
            ("traffic.condition", "实时路况 (通畅/拥堵)"),
            ("device.battery_level", "设备剩余电量百分比"),
            ("health.steps_today", "今日步数"),
            ("network.type", "当前网络类型 (wifi/cellular/ethernet/no_network)")
        ]

        print("\n    [信号转换] 原始信号数据: \(signals.count) 个")
        for (key, value) in signals {
            print("      - \(key) = \(value)")
        }
        
        let results = signalDescriptions.compactMap { signal, desc in
            if let value = signals[signal] {
                return SignalDescription(signal: signal, desc: desc, value: value)
            } else {
                print("      ⚠️ 缺失信号: \(signal)")
                return nil
            }
        }
        
        print("    [信号转换] 转换完成: \(results.count)/\(signalDescriptions.count) 个信号")
        
        return results
    }

    // MARK: - Signal Collectors

    private func collectTimeSignals(for event: Event?) -> [String: Any] {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = timeZoneManager.currentTimeZone

        var context: [String: Any] = [
            "time.current": formatter.string(from: now),
            "date.current": DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none),
        ]

        // 如果有事件，更新事件时间信息
        if let event = event {
            context["time.event_start"] = event.startDate?.ISO8601Format() ?? "unknown"
            context["time.event_end"] = event.endDate?.ISO8601Format() ?? "unknown"

            // 分析日程
            let scheduleContext = scheduleAnalyzer.analyzeScheduleContext(currentEvent: event)
            context.merge(scheduleContext) { _, new in new }
        } else {
            // 没有事件时也设置默认值
            context["time.event_start"] = "none"
            context["time.event_end"] = "none"
            
            // 仍然可以分析当前时间点的日程情况
            let now = Date()
            let dummyEvent = Event(
                title: "current_analysis",
                startDate: now,
                endDate: now.addingTimeInterval(3600),
                location: nil,
                isAllDay: false
            )
            let scheduleContext = scheduleAnalyzer.analyzeScheduleContext(currentEvent: dummyEvent)
            context.merge(scheduleContext) { _, new in new }
        }
        
        print("    [时间信号] 收集完成: \(context.keys.joined(separator: ", "))")
        return context
    }

    private func collectLocationSignals(for event: Event?) async -> [String: Any] {
        var context: [String: Any] = [:]

        // 尝试获取当前位置
        if let location = dataManager.locationManagerInstance.location {
            let coordinate = location.coordinate
            let latlon = "\(coordinate.latitude),\(coordinate.longitude)"

            // 异步获取地址
            let address = await locationService.getFullLocationDescription(for: location)

            // 简化判断逻辑 (后续可优化为地理围栏)
            let isAtHome = address.contains("家") || address.contains("住所") || address.contains("home")
            let isAtWork = address.contains("公司") || address.contains("办公室") || address.contains("office")

            context["location.user_current_latlon"] = latlon
            context["location.user_current_semantic"] = address
            context["location.is_at_home"] = isAtHome
            context["location.is_at_work"] = isAtWork
            
            print("    [位置信号] 当前位置: \(address)")
        } else {
            context["location.user_current_latlon"] = "unavailable"
            context["location.user_current_semantic"] = "unavailable"
            context["location.is_at_home"] = false
            context["location.is_at_work"] = false
            print("    [位置信号] ⚠️ 无法获取当前位置")
        }

        // 如果有事件，添加事件位置信息
        if let event = event, let eventLocation = event.location {
            context["location.event_semantic"] = eventLocation
            context["location.event_latlon"] = "pending_geocoding" // TODO: 解析事件地址为坐标
        } else {
            context["location.event_semantic"] = "none"
            context["location.event_latlon"] = "none"
        }
        
        print("    [位置信号] 收集完成: \(context.keys.joined(separator: ", "))")
        return context
    }

    private func collectExternalSignals(for event: Event) async -> [String: Any] {
        var context: [String: Any] = [:]

        // 天气信息
        if let eventStart = event.startDate,
           let eventLocation = dataManager.locationManagerInstance.location {
            print("    [外部信号] 正在获取天气信息...")
            let weather = await weatherService.getForecast(
                for: eventLocation.coordinate,
                at: eventStart
            )
            context["weather.forecast_at_event"] = weather
            print("    [外部信号] 天气: \(weather)")
        } else {
            context["weather.forecast_at_event"] = "unavailable"
            print("    [外部信号] ⚠️ 天气信息不可用（缺少位置或时间）")
        }

        // 交通信息
        if let userLocation = dataManager.locationManagerInstance.location,
           let eventLocation = event.location, eventLocation != "current_location" {
            print("    [外部信号] 正在获取交通信息...")
            let traffic = await trafficService.getRouteInfo(
                from: userLocation.coordinate,
                toParseAddress: eventLocation
            )
            context["traffic.eta_to_event"] = traffic.eta
            context["traffic.condition"] = traffic.condition
            print("    [外部信号] 交通: ETA=\(traffic.eta)分钟, 路况=\(traffic.condition)")
        } else {
            context["traffic.eta_to_event"] = -1
            context["traffic.condition"] = "not_applicable"
            print("    [外部信号] ⚠️ 交通信息不适用（无事件地点或当前位置）")
        }
        
        print("    [外部信号] 收集完成: \(context.keys.joined(separator: ", "))")
        return context
    }

    // MARK: - Utility Methods

    /// 获取网络类型（wifi/cellular/ethernet/no_network）
    private func getNetworkType() -> String? {
        #if targetEnvironment(simulator)
        return "wifi"
        #else
        return checkNetworkType()
        #endif
    }
    
    private func checkNetworkType() -> String {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var result = "unknown"
        
        monitor.pathUpdateHandler = { path in
            if path.usesInterfaceType(.wifi) {
                result = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                result = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                result = "ethernet"
            } else if path.status == .satisfied {
                result = "other_network"
            } else {
                result = "no_network"
            }
            semaphore.signal()
        }
        
        let queue = DispatchQueue(label: "NetworkTypeCheck")
        monitor.start(queue: queue)
        
        // 等待最多 0.5 秒
        _ = semaphore.wait(timeout: .now() + 0.5)
        monitor.cancel()
        
        return result
    }

    private func getBatteryLevel() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int(level * 100) : -1
    }

    private func getCurrentAudioInfo() -> (level: String, type: String) {
        // 使用DataManager的音频采集逻辑
        let level = dataManager.getCurrentAudioLevel()
        
        // 基于音量简单推断声音类型
        if let dbValue = Double(level.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)) {
            switch dbValue {
            case 0..<20:
                return (level, "silent")
            case 20..<40:
                return (level, "quiet")
            case 40..<60:
                return (level, "normal_speech")
            case 60..<80:
                return (level, "loud_speech_or_music")
            case 80...:
                return (level, "very_loud_or_traffic")
            default:
                return (level, "unknown")
            }
        }
        
        return (level, "unknown")
    }

    private func getTodaySteps() async -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { return -1 }
        
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        
        // Check authorization status
        let status = healthStore.authorizationStatus(for: stepsType)
        if status == .notDetermined {
             // Request authorization
             try? await healthStore.requestAuthorization(toShare: [], read: [stepsType])
        }
        
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)
        
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepsType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                guard let result = result, let sum = result.sumQuantity() else {
                    continuation.resume(returning: 0)
                    return
                }
                let steps = Int(sum.doubleValue(for: HKUnit.count()))
                continuation.resume(returning: steps)
            }
            healthStore.execute(query)
        }
    }
}

// MARK: - Event Support
public struct Event {
    public let title: String
    public let startDate: Date?
    public let endDate: Date?
    public let location: String?
    public let isAllDay: Bool

    public init(title: String, startDate: Date?, endDate: Date?, location: String?, isAllDay: Bool) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.isAllDay = isAllDay
    }
}
