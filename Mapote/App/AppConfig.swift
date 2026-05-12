import Foundation

enum AppConfigKey {
    static let geminiAPIKey = "app-config-gemini-api-key"
    static let googleMapsKey = "app-config-google-maps-key"
    static let amapKey = "app-config-amap-key"
    static let mapDataInterfaceEnabled = "app-config-map-data-interface-enabled"
}

struct AppConfig {
    static let fallbackGoogleMapsKey = "YOUR_GOOGLE_MAPS_API_KEY"

    var geminiAPIKey: String
    var googleMapsKey: String
    var amapKey: String
    var mapDataInterfaceEnabled: Bool

    static func load() -> AppConfig {
        let googleKey = UserDefaults.standard.string(forKey: AppConfigKey.googleMapsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AppConfig(
            geminiAPIKey: UserDefaults.standard.string(forKey: AppConfigKey.geminiAPIKey) ?? "",
            googleMapsKey: googleKey.isEmpty ? fallbackGoogleMapsKey : googleKey,
            amapKey: UserDefaults.standard.string(forKey: AppConfigKey.amapKey) ?? "",
            mapDataInterfaceEnabled: UserDefaults.standard.bool(forKey: AppConfigKey.mapDataInterfaceEnabled)
        )
    }

    func save() {
        UserDefaults.standard.set(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppConfigKey.geminiAPIKey)
        UserDefaults.standard.set(googleMapsKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppConfigKey.googleMapsKey)
        UserDefaults.standard.set(amapKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppConfigKey.amapKey)
        UserDefaults.standard.set(mapDataInterfaceEnabled, forKey: AppConfigKey.mapDataInterfaceEnabled)
    }
}

