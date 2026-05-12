import Foundation
import SwiftUI
import CoreLocation

extension Color {
    init(hex: String, alpha: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (37, 99, 235)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: alpha)
    }
}

extension PlaceCategory {
    var color: Color { Color(hex: colorHex) }
    var chipBackground: Color { Color(hex: colorHex, alpha: 0.18) }
    var iconBackground: Color { Color(hex: colorHex, alpha: 0.20) }
}

extension Array where Element == Place {
    var averageLatLng: LatLng? {
        guard !isEmpty else { return nil }
        let lat = reduce(0.0) { $0 + $1.lat } / Double(count)
        let lng = reduce(0.0) { $0 + $1.lng } / Double(count)
        return LatLng(lat: lat, lng: lng)
    }
}

extension CLLocationCoordinate2D {
    init(_ latLng: LatLng) {
        self.init(latitude: latLng.lat, longitude: latLng.lng)
    }
}

extension LatLng {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

extension String {
    var isCJK: Bool {
        contains { char in
            guard let scalar = char.unicodeScalars.first else { return false }
            return (0x4E00...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

enum DistanceFormatterUtil {
    static func humanDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(Int(meters)) m"
    }

    static func humanDuration(_ seconds: Double) -> String {
        if seconds >= 3600 {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return m == 0 ? "\(h)小时" : "\(h)小时\(m)分"
        }
        return "\(max(1, Int(seconds / 60)))分钟"
    }
}

