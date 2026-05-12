import Foundation

enum CoordTransform {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323
    private static let pi = Double.pi

    static func outOfChina(lng: Double, lat: Double) -> Bool {
        lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    static func wgs84ToGcj02(lng: Double, lat: Double) -> (lng: Double, lat: Double) {
        if outOfChina(lng: lng, lat: lat) { return (lng, lat) }
        let dLat = transformLat(x: lng - 105.0, y: lat - 35.0)
        let dLng = transformLng(x: lng - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let mgLat = lat + (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
        let mgLng = lng + (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
        return (mgLng, mgLat)
    }

    static func gcj02ToWgs84(lng: Double, lat: Double) -> (lng: Double, lat: Double) {
        var initLng = lng
        var initLat = lat
        for _ in 0..<5 {
            let converted = wgs84ToGcj02(lng: initLng, lat: initLat)
            let dLng = converted.lng - lng
            let dLat = converted.lat - lat
            initLng -= dLng
            initLat -= dLat
        }
        return (initLng, initLat)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return ret
    }
}

