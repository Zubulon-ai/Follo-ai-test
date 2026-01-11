//
//  TrafficService.swift
//  Follo AI
//
//  基于MapKit的交通信息服务
//

import MapKit

class TrafficService {
    func getRouteInfo(from: CLLocationCoordinate2D, toParseAddress address: String) async -> (eta: Int, condition: String) {
        // 1. 解析地址为坐标
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            guard let destination = placemarks.first?.location else {
                return (-1, "unknown")
            }

            // 2. 获取路线信息
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
            request.transportType = .automobile

            let directions = try await MKDirections(request: request).calculate()
            let route = directions.routes.first

            let eta = Int(route?.expectedTravelTime ?? 0) / 60  // 转换为分钟
            let condition = route != nil ? "available" : "unavailable"

            return (eta, condition)
        } catch {
            print("获取交通信息失败: \(error)")
            return (-1, "error")
        }
    }
}
