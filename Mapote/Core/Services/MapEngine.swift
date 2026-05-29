import Foundation
import MapKit

protocol MapEngine {
    var type: MapEngineType { get }
    func loadScript() async throws
    func isLoaded() -> Bool
    func textSearch(query: String, options: SearchOptions?) async -> [MapPlace]
    func findPlace(query: String, options: SearchOptions?) async -> MapPlace?
    func getPlaceDetails(placeId: String, fields: [String]?) async -> MapPlace?
    func getDirections(from: LatLng, to: LatLng, mode: TravelMode) async -> MapDirectionsResult?
}

enum MapEngineLoadError: LocalizedError {
    case missingAPIKey(String)
    case invalidAPIKey(String, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "缺少\(name) API Key"
        case .invalidAPIKey(let name, let detail):
            if let detail, !detail.isEmpty {
                return "\(name) API Key 无效：\(detail)"
            }
            return "\(name) API Key 无效或未开通对应服务"
        }
    }
}

final class NativeMapEngine: MapEngine {
    let type: MapEngineType
    private var loaded = false

    init(type: MapEngineType) {
        self.type = type
    }

    func loadScript() async throws {
        loaded = true
    }

    func isLoaded() -> Bool { loaded }

    func textSearch(query: String, options: SearchOptions?) async -> [MapPlace] {
        let key = "native:ts:\(type.rawValue):\(query.lowercased())"
        if let cached: [MapPlace] = await APICache.shared.get(key, type: [MapPlace].self) {
            return cached
        }

        let request = mkRequest(query: query, options: options)
        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.prefix(5).map(Self.mapPlace(from:))
            await APICache.shared.set(key, value: results)
            return results
        } catch {
            return []
        }
    }

    func findPlace(query: String, options: SearchOptions?) async -> MapPlace? {
        await textSearch(query: query, options: options).first
    }

    func getPlaceDetails(placeId: String, fields: [String]?) async -> MapPlace? {
        let key = "native:pd:\(type.rawValue):\(placeId)"
        if let cached: MapPlace = await APICache.shared.get(key, type: MapPlace.self) {
            return cached
        }
        let fallback = await findPlace(query: placeId, options: nil)
        if let fallback {
            await APICache.shared.set(key, value: fallback)
        }
        return fallback
    }

    func getDirections(from: LatLng, to: LatLng, mode: TravelMode) async -> MapDirectionsResult? {
        let key = "native:dir:\(type.rawValue):\(Self.directionKey(from: from, to: to, mode: mode))"
        if let cached: MapDirectionsResult = await APICache.shared.get(key, type: MapDirectionsResult.self) {
            return cached
        }

        let source = MKMapItem(placemark: MKPlacemark(coordinate: from.cl))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: to.cl))
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = transportType(for: mode)

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return nil }
            let result = MapDirectionsResult(
                distanceText: DistanceFormatterUtil.humanDistance(route.distance),
                durationText: DistanceFormatterUtil.humanDuration(route.expectedTravelTime),
                durationSeconds: Int(route.expectedTravelTime),
                polyline: route.polyline.points()
            )
            await APICache.shared.set(key, value: result)
            return result
        } catch {
            let fallback = Self.fallbackRoute(from: from, to: to, mode: mode)
            await APICache.shared.set(key, value: fallback)
            return fallback
        }
    }

    private func mkRequest(query: String, options: SearchOptions?) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = options?.city.map { "\($0) \(query)" } ?? query
        if let center = options?.locationBias?.cl {
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: Double(options?.radius ?? 50_000),
                longitudinalMeters: Double(options?.radius ?? 50_000)
            )
        }
        return request
    }

    private func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .DRIVING: return .automobile
        case .WALKING, .BICYCLING: return .walking
        case .TRANSIT: return .transit
        }
    }

    private static func mapPlace(from item: MKMapItem) -> MapPlace {
        let coordinate = item.placemark.coordinate
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        let name = item.name ?? "未知地点"
        let address = formatAddress(from: item)
        let categoryType = item.pointOfInterestCategory?.rawValue
        let types = categoryType.map { [$0] }
        let summary = placeSummary(from: item)

        return MapPlace(
            name: name,
            address: address,
            lat: lat,
            lng: lng,
            placeId: makeNativePlaceID(name: name, lat: lat, lng: lng),
            photoUrl: nil,
            photoUrls: nil,
            types: types,
            rating: nil,
            openingHours: nil,
            editorialSummary: summary,
            reviews: nil,
            openNow: nil
        )
    }

    private static func formatAddress(from item: MKMapItem) -> String {
        let placemark = item.placemark
        let parts = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return placemark.title ?? "未知地址"
    }

    private static func makeNativePlaceID(name: String, lat: Double, lng: Double) -> String {
        "mk:\(name.lowercased()):\(String(format: "%.5f", lat)):\(String(format: "%.5f", lng))"
    }

    private static func placeSummary(from item: MKMapItem) -> String? {
        var segments: [String] = []
        if let phone = item.phoneNumber, !phone.isEmpty {
            segments.append("电话 \(phone)")
        }
        if let url = item.url?.host, !url.isEmpty {
            segments.append("官网 \(url)")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    static func directionKey(from: LatLng, to: LatLng, mode: TravelMode) -> String {
        "\(String(format: "%.5f", from.lat)),\(String(format: "%.5f", from.lng))-\(String(format: "%.5f", to.lat)),\(String(format: "%.5f", to.lng)):\(mode.rawValue)"
    }

    static func fallbackRoute(from: LatLng, to: LatLng, mode: TravelMode) -> MapDirectionsResult {
        let straightMeters = from.cl.distance(from: to.cl)
        let speed: Double
        switch mode {
        case .WALKING:
            speed = 1.2
        case .BICYCLING:
            speed = 4.5
        case .TRANSIT:
            speed = 8.0
        case .DRIVING:
            speed = 11.0
        }
        let seconds = max(60, Int(straightMeters / speed))
        return MapDirectionsResult(
            distanceText: DistanceFormatterUtil.humanDistance(straightMeters),
            durationText: DistanceFormatterUtil.humanDuration(Double(seconds)),
            durationSeconds: seconds,
            polyline: [from, to]
        )
    }
}

final class GoogleMapEngine: MapEngine {
    let type: MapEngineType = .google
    private var loaded = false

    func loadScript() async throws {
        guard !resolvedKey.isEmpty else {
            throw MapEngineLoadError.missingAPIKey("Google 地图")
        }
        loaded = true
    }

    func isLoaded() -> Bool { loaded }

    func textSearch(query: String, options: SearchOptions?) async -> [MapPlace] {
        let cacheKey = "google:ts:\(query.lowercased()):\(options?.city ?? "")"
        if let cached: [MapPlace] = await APICache.shared.get(cacheKey, type: [MapPlace].self) {
            return cached
        }
        guard let url = googleTextSearchURL(query: query, options: options) else {
            return []
        }

        do {
            let json = try await fetchJSONObject(from: url)
            let status = json["status"] as? String
            guard status == "OK" || status == "ZERO_RESULTS" else {
                return []
            }
            let items = (json["results"] as? [[String: Any]] ?? []).prefix(5).compactMap(mapGooglePlace)
            let results = Array(items)
            await APICache.shared.set(cacheKey, value: results)
            return results
        } catch {
            return []
        }
    }

    func findPlace(query: String, options: SearchOptions?) async -> MapPlace? {
        await textSearch(query: query, options: options).first
    }

    func getPlaceDetails(placeId: String, fields: [String]?) async -> MapPlace? {
        let cacheKey = "google:pd:\(placeId)"
        if let cached: MapPlace = await APICache.shared.get(cacheKey, type: MapPlace.self) {
            return cached
        }
        guard let url = googleDetailsURL(placeId: placeId, fields: fields) else {
            return nil
        }
        do {
            let json = try await fetchJSONObject(from: url)
            guard (json["status"] as? String) == "OK",
                  let result = json["result"] as? [String: Any],
                  let place = mapGooglePlace(result)
            else {
                return nil
            }
            await APICache.shared.set(cacheKey, value: place)
            return place
        } catch {
            return nil
        }
    }

    func getDirections(from: LatLng, to: LatLng, mode: TravelMode) async -> MapDirectionsResult? {
        let cacheKey = "google:dir:\(NativeMapEngine.directionKey(from: from, to: to, mode: mode))"
        if let cached: MapDirectionsResult = await APICache.shared.get(cacheKey, type: MapDirectionsResult.self) {
            return cached
        }
        guard let url = googleDirectionsURL(from: from, to: to, mode: mode) else {
            return nil
        }

        do {
            let json = try await fetchJSONObject(from: url)
            guard (json["status"] as? String) == "OK",
                  let route = (json["routes"] as? [[String: Any]])?.first,
                  let leg = (route["legs"] as? [[String: Any]])?.first
            else {
                return nil
            }

            let polylineString = ((route["overview_polyline"] as? [String: Any])?["points"] as? String) ?? ""
            let result = MapDirectionsResult(
                distanceText: ((leg["distance"] as? [String: Any])?["text"] as? String) ?? "",
                durationText: ((leg["duration"] as? [String: Any])?["text"] as? String) ?? "",
                durationSeconds: ((leg["duration"] as? [String: Any])?["value"] as? Int) ?? 0,
                polyline: decodeGooglePolyline(polylineString)
            )
            await APICache.shared.set(cacheKey, value: result)
            return result
        } catch {
            return nil
        }
    }

    private var resolvedKey: String {
        AppConfig.load().googleMapsKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func googleTextSearchURL(query: String, options: SearchOptions?) -> URL? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/textsearch/json")
        var queryText = query
        if let city = options?.city, !city.isEmpty, !query.contains(city) {
            queryText = "\(city) \(query)"
        }
        var items = [
            URLQueryItem(name: "query", value: queryText),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "key", value: resolvedKey)
        ]
        if let bias = options?.locationBias {
            items.append(URLQueryItem(name: "location", value: "\(bias.lat),\(bias.lng)"))
            items.append(URLQueryItem(name: "radius", value: String(options?.radius ?? 50_000)))
        }
        components?.queryItems = items
        return components?.url
    }

    private func googleDetailsURL(placeId: String, fields: [String]?) -> URL? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/details/json")
        let resolvedFields = (fields?.joined(separator: ",").isEmpty == false) ? fields!.joined(separator: ",") : "name,formatted_address,geometry,photos,opening_hours,rating,editorial_summary,reviews,types,place_id"
        components?.queryItems = [
            URLQueryItem(name: "place_id", value: placeId),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "fields", value: resolvedFields),
            URLQueryItem(name: "key", value: resolvedKey)
        ]
        return components?.url
    }

    private func googleDirectionsURL(from: LatLng, to: LatLng, mode: TravelMode) -> URL? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/directions/json")
        components?.queryItems = [
            URLQueryItem(name: "origin", value: "\(from.lat),\(from.lng)"),
            URLQueryItem(name: "destination", value: "\(to.lat),\(to.lng)"),
            URLQueryItem(name: "mode", value: googleTravelMode(mode)),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "key", value: resolvedKey)
        ]
        return components?.url
    }

    private func googleTravelMode(_ mode: TravelMode) -> String {
        switch mode {
        case .DRIVING: return "driving"
        case .WALKING: return "walking"
        case .BICYCLING: return "bicycling"
        case .TRANSIT: return "transit"
        }
    }

    private func mapGooglePlace(_ raw: [String: Any]) -> MapPlace? {
        guard let geometry = raw["geometry"] as? [String: Any],
              let location = geometry["location"] as? [String: Any],
              let lat = location["lat"] as? Double,
              let lng = location["lng"] as? Double
        else { return nil }

        let photos = (raw["photos"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard let ref = item["photo_reference"] as? String else { return nil }
            var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/photo")
            components?.queryItems = [
                URLQueryItem(name: "maxwidth", value: "900"),
                URLQueryItem(name: "photo_reference", value: ref),
                URLQueryItem(name: "key", value: resolvedKey)
            ]
            return components?.url?.absoluteString
        }

        let reviews = (raw["reviews"] as? [[String: Any]] ?? []).compactMap { review -> PlaceReview? in
            guard let text = review["text"] as? String else { return nil }
            return PlaceReview(text: text, rating: review["rating"] as? Double)
        }

        return MapPlace(
            name: (raw["name"] as? String) ?? "未知地点",
            address: (raw["formatted_address"] as? String) ?? (raw["vicinity"] as? String) ?? "未知地址",
            lat: lat,
            lng: lng,
            placeId: (raw["place_id"] as? String),
            photoUrl: photos.first,
            photoUrls: photos.isEmpty ? nil : photos,
            types: raw["types"] as? [String],
            rating: raw["rating"] as? Double,
            openingHours: ((raw["opening_hours"] as? [String: Any])?["weekday_text"] as? [String]),
            editorialSummary: ((raw["editorial_summary"] as? [String: Any])?["overview"] as? String) ?? ((raw["editorial_summary"] as? [String: Any])?["text"] as? String),
            reviews: reviews.isEmpty ? nil : reviews,
            openNow: ((raw["opening_hours"] as? [String: Any])?["open_now"] as? Bool)
        )
    }
}

final class AmapMapEngine: MapEngine {
    let type: MapEngineType = .amap
    private var loaded = false

    func loadScript() async throws {
        guard !resolvedKey.isEmpty else {
            throw MapEngineLoadError.missingAPIKey("高德")
        }
        loaded = true
    }

    func isLoaded() -> Bool { loaded }

    func textSearch(query: String, options: SearchOptions?) async -> [MapPlace] {
        let locationKey = options?.locationBias.map { ":\(String(format: "%.5f", $0.lat)),\(String(format: "%.5f", $0.lng)):\(options?.radius ?? 0)" } ?? ""
        let cacheKey = "amap:ts:v2:\(query.lowercased()):\(options?.city ?? "")\(locationKey)"
        if let cached: [MapPlace] = await APICache.shared.get(cacheKey, type: [MapPlace].self) {
            return cached
        }
        guard let url = amapSearchURL(query: query, options: options) else {
            return []
        }
        do {
            let json = try await fetchJSONObject(from: url)
            guard (json["status"] as? String) == "1" else {
                print("[Amap] textSearch failed: \(json["info"] as? String ?? "unknown") (\(json["infocode"] as? String ?? ""))")
                return []
            }
            let results = ((json["pois"] as? [[String: Any]]) ?? []).prefix(5).compactMap(mapAmapPlace)
            let mapped = Array(results)
            await APICache.shared.set(cacheKey, value: mapped)
            return mapped
        } catch {
            print("[Amap] textSearch error: \(error.localizedDescription)")
            return []
        }
    }

    func findPlace(query: String, options: SearchOptions?) async -> MapPlace? {
        await textSearch(query: query, options: options).first
    }

    func getPlaceDetails(placeId: String, fields: [String]?) async -> MapPlace? {
        let cacheKey = "amap:pd:v2:\(placeId)"
        if let cached: MapPlace = await APICache.shared.get(cacheKey, type: MapPlace.self) {
            return cached
        }
        var components = URLComponents(string: "https://restapi.amap.com/v3/place/detail")
        components?.queryItems = [
            URLQueryItem(name: "key", value: resolvedKey),
            URLQueryItem(name: "id", value: placeId),
            URLQueryItem(name: "extensions", value: "all")
        ]
        guard let url = components?.url else {
            return nil
        }
        do {
            let json = try await fetchJSONObject(from: url)
            guard (json["status"] as? String) == "1",
                  let poi = (json["pois"] as? [[String: Any]])?.first,
                  let place = mapAmapPlace(poi)
            else {
                print("[Amap] detail failed: \(json["info"] as? String ?? "unknown") (\(json["infocode"] as? String ?? ""))")
                return nil
            }
            await APICache.shared.set(cacheKey, value: place)
            return place
        } catch {
            print("[Amap] detail error: \(error.localizedDescription)")
            return nil
        }
    }

    func getDirections(from: LatLng, to: LatLng, mode: TravelMode) async -> MapDirectionsResult? {
        let cacheKey = "amap:dir:\(NativeMapEngine.directionKey(from: from, to: to, mode: mode))"
        if let cached: MapDirectionsResult = await APICache.shared.get(cacheKey, type: MapDirectionsResult.self) {
            return cached
        }
        guard let url = amapDirectionsURL(from: from, to: to, mode: mode) else {
            return nil
        }
        do {
            let json = try await fetchJSONObject(from: url)
            guard (json["status"] as? String) == "1" else {
                return nil
            }
            guard let result = mapAmapDirections(json: json, mode: mode) else {
                return nil
            }
            await APICache.shared.set(cacheKey, value: result)
            return result
        } catch {
            return nil
        }
    }

    private var resolvedKey: String {
        AppConfig.load().amapKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func amapSearchURL(query: String, options: SearchOptions?) -> URL? {
        if let bias = options?.locationBias {
            let gcj = CoordTransform.wgs84ToGcj02(lng: bias.lng, lat: bias.lat)
            var components = URLComponents(string: "https://restapi.amap.com/v3/place/around")
            components?.queryItems = [
                URLQueryItem(name: "key", value: resolvedKey),
                URLQueryItem(name: "keywords", value: query),
                URLQueryItem(name: "location", value: "\(gcj.lng),\(gcj.lat)"),
                URLQueryItem(name: "radius", value: String(options?.radius ?? 50_000)),
                URLQueryItem(name: "offset", value: "5"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "extensions", value: "all"),
                URLQueryItem(name: "sortrule", value: "distance")
            ]
            return components?.url
        }

        var components = URLComponents(string: "https://restapi.amap.com/v3/place/text")
        components?.queryItems = [
            URLQueryItem(name: "key", value: resolvedKey),
            URLQueryItem(name: "keywords", value: query),
            URLQueryItem(name: "city", value: options?.city),
            URLQueryItem(name: "offset", value: "5"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "extensions", value: "all")
        ].filter { $0.value?.isEmpty == false }
        return components?.url
    }

    private func amapDirectionsURL(from: LatLng, to: LatLng, mode: TravelMode) -> URL? {
        let fromGcj = CoordTransform.wgs84ToGcj02(lng: from.lng, lat: from.lat)
        let toGcj = CoordTransform.wgs84ToGcj02(lng: to.lng, lat: to.lat)
        let endpoint: String
        switch mode {
        case .DRIVING:
            endpoint = "https://restapi.amap.com/v3/direction/driving"
        case .WALKING, .BICYCLING:
            endpoint = "https://restapi.amap.com/v3/direction/walking"
        case .TRANSIT:
            return nil
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "key", value: resolvedKey),
            URLQueryItem(name: "origin", value: "\(fromGcj.lng),\(fromGcj.lat)"),
            URLQueryItem(name: "destination", value: "\(toGcj.lng),\(toGcj.lat)")
        ]
        return components?.url
    }

    private func mapAmapPlace(_ raw: [String: Any]) -> MapPlace? {
        let locationString = (raw["location"] as? String) ?? ""
        let components = locationString.split(separator: ",")
        guard components.count == 2,
              let gcjLng = Double(components[0]),
              let gcjLat = Double(components[1])
        else { return nil }

        let converted = CoordTransform.gcj02ToWgs84(lng: gcjLng, lat: gcjLat)
        let photos = (raw["photos"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard let url = item["url"] as? String else { return nil }
            return normalizePhotoURL(url)
        }
        let hours = (raw["business"] as? [String: Any])?["opentime_today"] as? String

        return MapPlace(
            name: (raw["name"] as? String) ?? "未知地点",
            address: (raw["address"] as? String) ?? (raw["pname"] as? String) ?? "未知地址",
            lat: converted.lat,
            lng: converted.lng,
            placeId: raw["id"] as? String,
            photoUrl: photos.first,
            photoUrls: photos.isEmpty ? nil : photos,
            types: (raw["type"] as? String)?.split(separator: ";").map(String.init),
            rating: nil,
            openingHours: hours.map { [$0] },
            editorialSummary: raw["tag"] as? String,
            reviews: nil,
            openNow: nil
        )
    }

    private func normalizePhotoURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        return components.url?.absoluteString ?? trimmed
    }

    private func mapAmapDirections(json: [String: Any], mode: TravelMode) -> MapDirectionsResult? {
        guard let route = (json["route"] as? [String: Any]) else { return nil }
        let paths = (route["paths"] as? [[String: Any]]) ?? []
        guard let firstPath = paths.first else { return nil }

        let distance = Double((firstPath["distance"] as? String) ?? "") ?? 0
        let duration = Int((firstPath["duration"] as? String) ?? "") ?? 0
        var points: [LatLng] = []

        let steps = (firstPath["steps"] as? [[String: Any]]) ?? []
        for step in steps {
            let polyline = (step["polyline"] as? String) ?? ""
            points.append(contentsOf: decodeAmapPolyline(polyline))
        }

        if points.isEmpty {
            points = []
        }

        return MapDirectionsResult(
            distanceText: DistanceFormatterUtil.humanDistance(distance),
            durationText: DistanceFormatterUtil.humanDuration(Double(duration)),
            durationSeconds: duration,
            polyline: points.isEmpty ? [] : points
        )
    }
}

private func fetchJSONObject(from url: URL) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
        throw URLError(.badServerResponse)
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw URLError(.cannotParseResponse)
    }
    return object
}

private func decodeGooglePolyline(_ encoded: String) -> [LatLng] {
    var coordinates: [LatLng] = []
    var index = encoded.startIndex
    var lat = 0
    var lng = 0

    while index < encoded.endIndex {
        var result = 0
        var shift = 0
        var byte: Int

        repeat {
            byte = Int(encoded[index].asciiValue ?? 63) - 63
            result |= (byte & 0x1F) << shift
            shift += 5
            index = encoded.index(after: index)
        } while byte >= 0x20 && index < encoded.endIndex

        lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

        result = 0
        shift = 0

        repeat {
            byte = Int(encoded[index].asciiValue ?? 63) - 63
            result |= (byte & 0x1F) << shift
            shift += 5
            index = encoded.index(after: index)
        } while byte >= 0x20 && index < encoded.endIndex

        lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        coordinates.append(LatLng(lat: Double(lat) / 100_000, lng: Double(lng) / 100_000))
    }

    return coordinates
}

private func decodeAmapPolyline(_ polyline: String) -> [LatLng] {
    polyline
        .split(separator: ";")
        .compactMap { pair -> LatLng? in
            let values = pair.split(separator: ",")
            guard values.count == 2,
                  let lng = Double(values[0]),
                  let lat = Double(values[1])
            else { return nil }
            let converted = CoordTransform.gcj02ToWgs84(lng: lng, lat: lat)
            return LatLng(lat: converted.lat, lng: converted.lng)
        }
}

private extension MKPolyline {
    func points() -> [LatLng] {
        var coords = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords.map { LatLng(lat: $0.latitude, lng: $0.longitude) }
    }
}

private extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
