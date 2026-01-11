//
//  LocationService.swift
//  Follo AI
//
//  Created by 邹昕恺 on 2025/8/13.
//

import Foundation
import CoreLocation
import MapKit

class LocationService: NSObject, ObservableObject {
    private let geocoder = CLGeocoder()
    private let chineseLocale = Locale(identifier: "zh_CN") // 指定中文（简体）
    
    override init() {
        super.init()
        setupChineseLocale()
    }
    
    private func setupChineseLocale() {
        print("LocationService initialized for Chinese localization")
        print("Using locale: \(chineseLocale.identifier)")
    }
    
    /// 格式化中文地址
    /// - Parameter placemark: CLPlacemark对象
    /// - Returns: 格式化的中文地址字符串
    private func formatChineseAddress(from placemark: CLPlacemark) -> String {
        var addressParts: [String] = []
        
        // 按照中文地址习惯排序：国家-省份-城市-区县-街道-门牌号
        if let country = placemark.country {
            addressParts.append(country)
        }
        
        if let administrativeArea = placemark.administrativeArea {
            addressParts.append(administrativeArea)
        }
        
        if let locality = placemark.locality {
            addressParts.append(locality)
        }
        
        if let subLocality = placemark.subLocality {
            addressParts.append(subLocality)
        }
        
        if let thoroughfare = placemark.thoroughfare {
            addressParts.append(thoroughfare)
        }
        
        if let subThoroughfare = placemark.subThoroughfare {
            addressParts.append("\(subThoroughfare)号")
        }
        
        // 使用空格分隔各个地址要素，让显示更清晰
        return addressParts.joined(separator: " ")
    }
    
    /// 将经纬度转换为地理位置描述
    /// - Parameter location: CLLocation对象
    /// - Returns: 地理位置描述字符串
    func convertLocationToAddress(location: CLLocation) async -> String {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            
            guard let placemark = placemarks.first else {
                return "无法获取地址信息"
            }
            
            let address = formatChineseAddress(from: placemark)
            
            if address.isEmpty {
                return "位置信息不完整"
            }
            
            return address
            
        } catch {
            return "地址解析失败: \(error.localizedDescription)"
        }
    }
    
    /// 获取详细的位置信息（包括POI信息）
    /// - Parameter location: CLLocation对象
    /// - Returns: 详细位置信息
    func getDetailedLocationInfo(location: CLLocation) async -> LocationInfo {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            
            guard let placemark = placemarks.first else {
                return LocationInfo(
                    address: "无法获取地址信息",
                    poi: nil,
                    region: nil,
                    coordinate: location.coordinate
                )
            }
            
            // 使用统一的中文地址格式化函数
            let address = formatChineseAddress(from: placemark)
            let finalAddress = address.isEmpty ? "位置信息不完整" : address
            
            // POI信息
            let poi = placemark.name
            
            // 区域信息
            let region = placemark.administrativeArea
            
            return LocationInfo(
                address: finalAddress,
                poi: poi,
                region: region,
                coordinate: location.coordinate
            )
            
        } catch {
            return LocationInfo(
                address: "地址解析失败: \(error.localizedDescription)",
                poi: nil,
                region: nil,
                coordinate: location.coordinate
            )
        }
    }
    
    /// 获取完整的地理位置描述（仅地址信息，不包含坐标）
    /// - Parameter location: CLLocation对象
    /// - Returns: 完整的地理位置描述字符串
    func getFullLocationDescription(for location: CLLocation) async -> String {
        // 使用中文locale进行地理编码
        let chineseAddress = await reverseGeocodeWithChineseLocale(location: location)
        return chineseAddress
    }
    
    /// 使用中文locale进行反向地理编码
    /// - Parameter location: CLLocation对象
    /// - Returns: 中文地址描述
    private func reverseGeocodeWithChineseLocale(location: CLLocation) async -> String {
        do {
            // 尝试设置中文环境变量来影响地理编码结果
            setenv("LANG", "zh_CN.UTF-8", 1)
            setenv("LC_ALL", "zh_CN.UTF-8", 1)
            
            // 创建一个新的CLGeocoder
            let chineseGeocoder = CLGeocoder()
            
            // 执行地理编码
            let placemarks = try await chineseGeocoder.reverseGeocodeLocation(location, preferredLocale: chineseLocale)
            
            guard let placemark = placemarks.first else {
                return "无法获取地址信息"
            }
            
            // print("=== Placemark data ===")
            // print("Country: \(placemark.country ?? "nil")")
            // print("AdministrativeArea: \(placemark.administrativeArea ?? "nil")")
            // print("Locality: \(placemark.locality ?? "nil")")
            // print("SubLocality: \(placemark.subLocality ?? "nil")")
            // print("Thoroughfare: \(placemark.thoroughfare ?? "nil")")
            // print("Name: \(placemark.name ?? "nil")")
            
            // 检查是否包含中文字符
            let hasChinese = containsChineseCharacters(placemark)
            print("Contains Chinese characters: \(hasChinese)")
            
            // 构建地址描述
            var locationComponents: [String] = []
            
            // 基础地址
            let baseAddress = formatChineseAddress(from: placemark)
            if !baseAddress.isEmpty {
                locationComponents.append(baseAddress)
            }
            
            // 添加POI信息（无论是否为空）
            if let poi = placemark.name {
                if !poi.isEmpty && !baseAddress.contains(poi) {
                    // POI有内容且不与地址重复，显示POI名称
                    locationComponents.append("(\(poi))")
                } else if poi.isEmpty {
                    // POI为空，显示"无名称"
                    locationComponents.append("(无名称)")
                }
            } else {
                // 没有POI字段，显示"无名称"
                locationComponents.append("(无名称)")
            }
            
            let finalDescription = locationComponents.joined(separator: "")
            print("location", location)
            print("Final location description: \(finalDescription)")
            
            return finalDescription.isEmpty ? "位置信息不详" : finalDescription
            
        } catch {
            print("Geocoding error: \(error)")
            return "地理编码失败"
        }
    }
    
    /// 检查placemark是否包含中文字符
    /// - Parameter placemark: CLPlacemark对象
    /// - Returns: 是否包含中文字符
    private func containsChineseCharacters(_ placemark: CLPlacemark) -> Bool {
        let fields = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.name
        ]
        
        for field in fields {
            if let text = field,
               text.range(of: "\\p{Han}", options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    /// 格式化位置信息为字符串
    /// - Parameter locationInfo: 位置信息对象
    /// - Returns: 格式化的位置描述字符串
    func formatLocationInfo(_ locationInfo: LocationInfo) -> String {
        var result = "地址: \(locationInfo.address)"
        
        if let poi = locationInfo.poi, !poi.isEmpty {
            result += "\nPOI: \(poi)"
        }
        
        if let region = locationInfo.region, !region.isEmpty {
            result += "\n区域: \(region)"
        }
        
        result += "\n坐标: 纬度 \(String(format: "%.6f", locationInfo.coordinate.latitude)), 经度 \(String(format: "%.6f", locationInfo.coordinate.longitude))"
        
        return result
    }
}

// MARK: - Data Models

/// 位置信息数据结构
struct LocationInfo {
    let address: String         // 完整地址
    let poi: String?           // 兴趣点名称
    let region: String?        // 区域信息
    let coordinate: CLLocationCoordinate2D  // 坐标
}

/// 位置解析结果
struct LocationResult {
    let success: Bool
    let message: String
    let locationInfo: LocationInfo?
}
