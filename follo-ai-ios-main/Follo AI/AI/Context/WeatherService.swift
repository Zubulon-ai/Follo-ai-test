//
//  WeatherService.swift
//  Follo AI
//
//  基于WeatherKit的天气服务
//

import WeatherKit
import CoreLocation

class WeatherService {
    private let weatherManager = WeatherKit.WeatherService()

    func getForecast(for coordinate: CLLocationCoordinate2D, at date: Date) async -> String {
        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let weather = try await weatherManager.weather(for: location)
            return weather.currentWeather.condition.description
        } catch {
            print("获取天气信息失败: \(error)")
            return "unknown"
        }
    }
}
