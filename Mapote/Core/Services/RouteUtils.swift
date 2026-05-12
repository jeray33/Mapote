import Foundation
import CoreLocation

enum RouteUtils {
    static func key(_ a: Place, _ b: Place) -> String {
        "\(a.id)-\(b.id)"
    }

    static func nearestNeighborSort(_ places: [Place]) -> [Place] {
        guard places.count >= 3 else { return places }
        var ordered: [Place] = [places[0]]
        var remaining = Array(places.dropFirst())

        while let last = ordered.last, !remaining.isEmpty {
            let next = remaining.min { lhs, rhs in
                haversine(from: last, to: lhs) < haversine(from: last, to: rhs)
            }
            guard let next else { break }
            ordered.append(next)
            remaining.removeAll { $0.id == next.id }
        }
        return ordered
    }

    static func haversine(from a: Place, to b: Place) -> Double {
        let loc1 = CLLocation(latitude: a.lat, longitude: a.lng)
        let loc2 = CLLocation(latitude: b.lat, longitude: b.lng)
        return loc1.distance(from: loc2)
    }

    static func summarize(routeInfos: [String: RouteInfo]) -> (distance: String, duration: String) {
        var meters: Double = 0
        var seconds: Double = 0
        for info in routeInfos.values {
            meters += parseDistance(info.distance)
            seconds += parseDuration(info.duration)
        }
        return (DistanceFormatterUtil.humanDistance(meters), DistanceFormatterUtil.humanDuration(seconds))
    }

    static func parseDistance(_ text: String) -> Double {
        let lower = text.lowercased()
        let number = Double(lower.replacingOccurrences(of: "[^0-9\\.]", with: "", options: .regularExpression)) ?? 0
        if lower.contains("km") { return number * 1000 }
        if lower.contains("mi") { return number * 1609.34 }
        return number
    }

    static func parseDuration(_ text: String) -> Double {
        let lower = text.lowercased()
        if lower.contains("小时") || lower.contains("hour") || lower.contains("hr") {
            let parts = lower.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Double($0) }
            if parts.count >= 2 {
                return parts[0] * 3600 + parts[1] * 60
            }
            if let h = parts.first {
                return h * 3600
            }
        }
        let m = Double(lower.replacingOccurrences(of: "[^0-9\\.]", with: "", options: .regularExpression)) ?? 0
        return m * 60
    }
}

