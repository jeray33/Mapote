import Foundation

actor APICache {
    static let shared = APICache()

    private struct Entry: Codable {
        var timestamp: TimeInterval
        var payload: Data
    }

    private var memory: [String: Entry] = [:]
    private let memoryTTL: TimeInterval = 30 * 60
    private let persistentTTL: TimeInterval = 24 * 60 * 60
    private let prefix = "api-cache:"

    func get<T: Decodable>(_ key: String, type: T.Type) -> T? {
        let now = Date().timeIntervalSince1970
        if let item = memory[key], now - item.timestamp <= memoryTTL,
           let value = try? JSONDecoder().decode(T.self, from: item.payload) {
            return value
        }

        guard let raw = UserDefaults.standard.data(forKey: prefix + key),
              let stored = try? JSONDecoder().decode(Entry.self, from: raw),
              now - stored.timestamp <= persistentTTL,
              let value = try? JSONDecoder().decode(T.self, from: stored.payload)
        else {
            return nil
        }

        memory[key] = stored
        return value
    }

    func set<T: Encodable>(_ key: String, value: T) {
        guard let payload = try? JSONEncoder().encode(value) else { return }
        let entry = Entry(timestamp: Date().timeIntervalSince1970, payload: payload)
        memory[key] = entry
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: prefix + key)
        }
    }
}

