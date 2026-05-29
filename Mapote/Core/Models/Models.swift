import Foundation
import SwiftUI

enum PlaceCategory: String, Codable, CaseIterable, Identifiable {
    case food
    case lodging
    case attraction
    case shopping
    case transit
    case nature
    case services
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: return "美食餐饮"
        case .lodging: return "住宿酒店"
        case .attraction: return "景点古迹"
        case .shopping: return "购物商场"
        case .transit: return "交通枢纽"
        case .nature: return "自然户外"
        case .services: return "生活服务"
        case .other: return "其他"
        }
    }

    var colorHex: String {
        switch self {
        case .food: return "#ef4444"
        case .lodging: return "#8b5cf6"
        case .attraction: return "#f59e0b"
        case .shopping: return "#ec4899"
        case .transit: return "#6366f1"
        case .nature: return "#22c55e"
        case .services: return "#64748b"
        case .other: return "#2563eb"
        }
    }

    var sfSymbol: String {
        switch self {
        case .food: return "fork.knife"
        case .lodging: return "bed.double.fill"
        case .attraction: return "building.columns.fill"
        case .shopping: return "bag.fill"
        case .transit: return "tram.fill"
        case .nature: return "leaf.fill"
        case .services: return "building.2.fill"
        case .other: return "mappin.circle.fill"
        }
    }

    var emoji: String {
        switch self {
        case .food: return "🍜"
        case .lodging: return "🏨"
        case .attraction: return "🏛️"
        case .shopping: return "🛍️"
        case .transit: return "🚆"
        case .nature: return "🌳"
        case .services: return "🏢"
        case .other: return "🏙️"
        }
    }

    static func infer(from types: [String]?) -> PlaceCategory {
        guard let types, !types.isEmpty else { return .other }
        let lower = types.map { $0.lowercased() }

        let rules: [(PlaceCategory, [String])] = [
            (.food, ["restaurant", "cafe", "bakery", "bar", "food", "meal_delivery", "meal_takeaway", "night_club"]),
            (.lodging, ["lodging", "hotel", "motel", "resort"]),
            (.attraction, ["tourist_attraction", "museum", "church", "art_gallery", "amusement_park", "zoo", "aquarium", "stadium", "casino", "movie_theater", "bowling_alley", "spa", "temple", "shrine", "historic", "monument"]),
            (.shopping, ["shopping_mall", "store", "market", "supermarket", "clothing_store", "shoe_store", "jewelry_store", "book_store", "electronics_store", "department_store", "convenience_store", "furniture_store", "home_goods_store", "pet_store"]),
            (.transit, ["train_station", "bus_station", "airport", "subway_station", "transit_station", "taxi_stand", "light_rail_station"]),
            (.nature, ["park", "natural_feature", "campground", "rv_park", "garden", "beach"]),
            (.services, ["hospital", "pharmacy", "bank", "post_office", "police", "fire_station", "embassy", "city_hall", "courthouse", "library", "school", "university", "gym", "laundry", "car_repair", "gas_station", "parking", "atm"])
        ]

        for (category, keywords) in rules {
            if lower.contains(where: { type in keywords.contains(where: { type.contains($0) }) }) {
                return category
            }
        }
        return .other
    }
}

struct Place: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var note: String
    var image: String?
    var images: [String]?
    var placeId: String?
    var suggestedDuration: String?
    var description: String?
    var openingHours: [String]?
    var category: PlaceCategory?
    var types: [String]?
    var rating: Double?
    var openNow: Bool?

    init(
        id: String = UUID().uuidString,
        name: String,
        address: String,
        lat: Double,
        lng: Double,
        note: String = "",
        image: String? = nil,
        images: [String]? = nil,
        placeId: String? = nil,
        suggestedDuration: String? = nil,
        description: String? = nil,
        openingHours: [String]? = nil,
        category: PlaceCategory? = nil,
        types: [String]? = nil,
        rating: Double? = nil,
        openNow: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.lat = lat
        self.lng = lng
        self.note = note
        self.image = image
        self.images = images
        self.placeId = placeId
        self.suggestedDuration = suggestedDuration
        self.description = description
        self.openingHours = openingHours
        self.category = category ?? PlaceCategory.infer(from: types)
        self.types = types
        self.rating = rating
        self.openNow = openNow
    }
}

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case DRIVING
    case WALKING
    case BICYCLING
    case TRANSIT

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .DRIVING: return "car.fill"
        case .WALKING: return "figure.walk"
        case .BICYCLING: return "bicycle"
        case .TRANSIT: return "tram.fill"
        }
    }

    func next() -> TravelMode {
        switch self {
        case .DRIVING: return .WALKING
        case .WALKING: return .BICYCLING
        case .BICYCLING: return .TRANSIT
        case .TRANSIT: return .DRIVING
        }
    }
}

struct RouteInfo: Codable, Hashable {
    var distance: String
    var duration: String
    var travelMode: TravelMode
}

struct Note: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var markdown: String
    var blocks: Data?
    var places: [Place]
    var routeInfos: [String: RouteInfo]
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        title: String = "未命名笔记",
        markdown: String = "",
        blocks: Data? = nil,
        places: [Place] = [],
        routeInfos: [String: RouteInfo] = [:],
        createdAt: TimeInterval = Date().timeIntervalSince1970 * 1000,
        updatedAt: TimeInterval = Date().timeIntervalSince1970 * 1000
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.blocks = blocks
        self.places = places
        self.routeInfos = routeInfos
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct DeletedNote: Codable, Hashable {
    let id: String
    var deletedAt: TimeInterval
}

enum ViewMode: String, CaseIterable, Identifiable {
    case note
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "NOTE"
        case .list: return "LIST"
        }
    }
}

enum MapEngineType: String, Codable, CaseIterable, Identifiable {
    case google
    case amap

    var id: String { rawValue }
}

struct LatLng: Codable, Hashable {
    var lat: Double
    var lng: Double
}

struct SearchOptions {
    var locationBias: LatLng?
    var radius: Int?
    var city: String?
}

struct PlaceReview: Codable, Hashable {
    var text: String
    var rating: Double?
}

struct MapPlace: Codable, Hashable, Identifiable {
    var id: String { placeId ?? "\(name)-\(lat)-\(lng)" }
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var placeId: String?
    var photoUrl: String?
    var photoUrls: [String]?
    var types: [String]?
    var rating: Double?
    var openingHours: [String]?
    var editorialSummary: String?
    var reviews: [PlaceReview]?
    var openNow: Bool?
}

struct MapDirectionsResult: Codable, Hashable {
    var distanceText: String
    var durationText: String
    var durationSeconds: Int
    var polyline: [LatLng]
}

struct MapSettings: Codable {
    var theme: String = "default"
    var emphasis: String = "default"
    var showRoute: Bool = true
    var showConnections: Bool = true
    var showNumber: Bool = true
    var showName: Bool = true
    var markerClustering: Bool = false
    var showTraffic: Bool = true
    var showRoadLabels: Bool = true
    var showWaterLabels: Bool = true
    var poiToggles: [PlaceCategory: Bool] = Dictionary(uniqueKeysWithValues: PlaceCategory.allCases.map { ($0, true) })
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: String = UUID().uuidString
    var role: Role
    var content: String
}

struct AIExtractPlace: Codable, Hashable {
    var name: String
    var searchQuery: String
    var aliases: [String]?
    var kind: String?
}

struct AIExtractResult: Codable, Hashable {
    var region: String?
    var places: [AIExtractPlace]
}

struct AIPlaceCard: Codable, Hashable, Identifiable {
    var id: String { "\(name)-\(searchQuery)" }
    var name: String
    var searchQuery: String
    var reason: String?
    var tips: String?
}

struct AIPlaceGroup: Identifiable, Hashable {
    let id = UUID().uuidString
    var title: String
    var intro: String
    var places: [AIPlaceCard]
}
