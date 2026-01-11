//
//  TimeZoneManager.swift
//  Follo AI
//
//  Created by AI Assistant on 2025/9/9.
//

import Foundation
import CoreLocation

class TimeZoneManager: NSObject, ObservableObject {
    static let shared = TimeZoneManager()
    
    @Published var currentTimeZone: TimeZone = TimeZone.current
    @Published var timeZoneDisplayName: String = ""
    @Published var timeZoneAbbreviation: String = ""
    @Published var utcOffset: String = ""
    
    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    
    override init() {
        super.init()
        setupLocationManager()
        updateTimeZoneInfo()
        startTimeZoneMonitoring()
    }
    
    // MARK: - Setup
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }
    
    // MARK: - Public Methods
    
    /// 请求位置权限以实现基于位置的时区检测
    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            print("位置权限被拒绝，将使用系统默认时区")
        case .authorizedWhenInUse, .authorizedAlways:
            updateTimeZoneFromLocation()
        @unknown default:
            break
        }
    }
    
    /// 手动更新时区信息
    func updateTimeZoneInfo() {
        DispatchQueue.main.async {
            self.currentTimeZone = TimeZone.current
            self.timeZoneDisplayName = self.currentTimeZone.localizedName(for: .standard, locale: Locale.current) ?? self.currentTimeZone.identifier
            self.timeZoneAbbreviation = self.currentTimeZone.abbreviation() ?? ""
            
            let offset = self.currentTimeZone.secondsFromGMT()
            let hours = offset / 3600
            let minutes = abs(offset % 3600) / 60
            
            if offset >= 0 {
                self.utcOffset = String(format: "UTC+%d:%02d", hours, minutes)
            } else {
                self.utcOffset = String(format: "UTC%d:%02d", hours, minutes)
            }
        }
    }
    
    /// 基于位置检测时区
    private func updateTimeZoneFromLocation() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || 
              locationManager.authorizationStatus == .authorizedAlways else {
            return
        }
        
        locationManager.requestLocation()
    }
    
    // MARK: - Time Zone Monitoring
    private func startTimeZoneMonitoring() {
        // 监听系统时区变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemTimeZoneDidChange),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
        
        // 定期检查时区变化（每分钟检查一次）
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            self.checkTimeZoneChanges()
        }
    }
    
    @objc private func systemTimeZoneDidChange() {
        print("系统时区发生变化，正在更新...")
        updateTimeZoneInfo()
    }
    
    private func checkTimeZoneChanges() {
        let newTimeZone = TimeZone.current
        if newTimeZone.identifier != currentTimeZone.identifier {
            print("检测到时区变化: \(currentTimeZone.identifier) -> \(newTimeZone.identifier)")
            updateTimeZoneInfo()
        }
    }
    
    // MARK: - Formatting Helpers
    
    /// 获取带时区信息的日期格式器
    func dateFormatter(style: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .medium) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = timeStyle
        formatter.timeZone = currentTimeZone
        formatter.locale = Locale.current
        return formatter
    }
    
    /// 获取带时区信息的完整时间字符串
    func formatDateWithTimeZone(_ date: Date) -> String {
        let formatter = dateFormatter()
        let dateString = formatter.string(from: date)
        return "\(dateString) (\(timeZoneAbbreviation))"
    }
    
    /// 获取简洁的时区信息
    func getTimeZoneInfo() -> String {
        return "\(timeZoneDisplayName) (\(utcOffset))"
    }
    
    /// 将日期转换为当前时区
    func convertToCurrentTimeZone(_ date: Date) -> Date {
        return date
    }
    
    /// 获取当前时区的Calendar实例
    func currentCalendar() -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = currentTimeZone
        return calendar
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - CLLocationManagerDelegate
extension TimeZoneManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        
        // 基于位置获取时区信息（这里可以使用更精确的时区API）
        // 目前主要依赖系统的自动时区设置
        updateTimeZoneInfo()
        
        print("位置更新: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        print("当前时区: \(currentTimeZone.identifier)")
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("位置获取失败: \(error.localizedDescription)")
        // 失败时使用系统默认时区
        updateTimeZoneInfo()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            updateTimeZoneFromLocation()
        case .denied, .restricted:
            print("位置权限被拒绝，使用系统时区设置")
            updateTimeZoneInfo()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}



