import Foundation
import SwiftUI
import Combine

@MainActor
final class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var selectedNoteID: String?
    @Published var mapEngineType: MapEngineType = .google
    @Published var mapSettings: MapSettings = .init()
    @Published var mapEngineError: String?

    let nativeEngine = NativeMapEngine(type: .google)
    let googleEngine = GoogleMapEngine()
    let amapEngine = AmapMapEngine()

    private let notesKey = "place-notes"
    private let mapSettingKey = "map-settings"
    private let mapEngineTypeKey = "map-engine-type"

    init() {
        load()
        Task { await initializeMapEngine() }
    }

    var currentNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    var currentEngine: MapEngine {
        nativeEngine
    }

    var hasGoogleMapKey: Bool {
        !AppConfig.load().googleMapsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAmapMapKey: Bool {
        !AppConfig.load().amapKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBothMapKeys: Bool {
        hasGoogleMapKey && hasAmapMapKey
    }

    func isMapEngineAvailable(_ type: MapEngineType) -> Bool {
        switch type {
        case .google:
            return hasGoogleMapKey
        case .amap:
            return hasAmapMapKey
        }
    }

    func select(noteID: String?) {
        selectedNoteID = noteID
    }

    func createNoteAndOpen() {
        var note = Note(title: "未命名笔记", markdown: "# Day 1\n")
        note.updatedAt = Date().timeIntervalSince1970 * 1000
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        save()
    }

    func delete(noteID: String) {
        notes.removeAll { $0.id == noteID }
        if selectedNoteID == noteID {
            selectedNoteID = nil
        }
        save()
    }

    func updateNote(_ noteID: String, mutate: (inout Note) -> Void) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        mutate(&notes[idx])
        notes[idx].updatedAt = Date().timeIntervalSince1970 * 1000
        save()
    }

    func updateTitle(noteID: String, title: String) {
        updateNote(noteID) { $0.title = title }
    }

    func updateMarkdown(noteID: String, markdown: String) {
        updateNote(noteID) { $0.markdown = markdown }
    }

    /// Write the Tiptap JSON tree (source of truth). Markdown is kept as a derived cache.
    func updateBlocks(noteID: String, blocks: Data, markdown: String) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else {
            print("[NoteStore] updateBlocks: note \(noteID) not found")
            return
        }

        // Defensive: never overwrite real content with a trivial empty document.
        // The Tiptap editor can emit an empty single-paragraph snapshot during
        // WKWebView initialisation before the real content arrives via setContent.
        let incomingIsTrivial = isTrivialBlocksData(blocks) && markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let existingHasContent: Bool = {
            if let existing = notes[idx].blocks, !isTrivialBlocksData(existing) { return true }
            return !notes[idx].markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        if incomingIsTrivial && existingHasContent {
            print("[NoteStore] updateBlocks: BLOCKED trivial overwrite for note \(noteID)")
            return
        }

        guard notes[idx].blocks != blocks || notes[idx].markdown != markdown else { return }
        print("[NoteStore] updateBlocks: saving \(blocks.count) bytes, md=\(markdown.prefix(40))… for note \(noteID)")
        updateNote(noteID) {
            $0.blocks = blocks
            $0.markdown = markdown
        }
    }

    /// A trivial blocks payload is either empty or contains only a single empty paragraph.
    private func isTrivialBlocksData(_ data: Data) -> Bool {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return data.isEmpty }
        if arr.isEmpty { return true }
        if arr.count == 1,
           let type = arr[0]["type"] as? String, type == "paragraph",
           arr[0]["content"] == nil {
            return true
        }
        return false
    }

    func reorderPlaces(noteID: String, newOrder: [Place]) {
        updateNote(noteID) { note in
            let orderedIDs = newOrder.map(\.id)
            let remain = note.places.filter { !orderedIDs.contains($0.id) }
            note.places = newOrder + remain
            note.routeInfos = [:]
        }
    }

    /// Phase 4: reorder placeRef blocks inside the editor tree to match `newIDOrder`.
    /// `scopeTitle` restricts the reorder to a single H1 section ("Day 2", etc.).
    func reorderPlacesInBlocks(noteID: String, newIDOrder: [String], scopeTitle: String? = nil) {
        updateNote(noteID) { note in
            let scope: BlocksService.ScopePredicate = scopeTitle.map { .section(title: $0) } ?? .all
            note.blocks = BlocksService.reorderingPlaces(note.blocks, newOrder: newIDOrder, scope: scope)
            // markdown will be re-derived next time the editor opens; clear stale routes.
            note.routeInfos = [:]
        }
    }

    func upsertPlace(noteID: String, place: Place, insertText: String?) {
        updateNote(noteID) { note in
            if !note.places.contains(where: { $0.id == place.id }) {
                note.places.append(place)
            }
            if let insertText, !insertText.isEmpty {
                let append = note.markdown.isEmpty ? insertText : "\n\(insertText)"
                note.markdown += append
                note.blocks = nil
            }
        }
    }

    func removePlace(noteID: String, placeID: String) {
        updateNote(noteID) { note in
            note.places.removeAll { $0.id == placeID }
            note.markdown = note.markdown.replacingOccurrences(of: "::place\\[[^\\]]*\\]\\{#\(NSRegularExpression.escapedPattern(for: placeID))\\}", with: "", options: .regularExpression)
            note.blocks = BlocksService.removingPlaceRef(note.blocks, placeID: placeID)
            note.routeInfos = note.routeInfos.filter { !$0.key.contains(placeID) }
        }
    }

    func setRouteInfo(noteID: String, key: String, info: RouteInfo) {
        updateNote(noteID) { $0.routeInfos[key] = info }
    }

    func replaceRouteInfos(noteID: String, routeInfos: [String: RouteInfo]) {
        updateNote(noteID) { $0.routeInfos = routeInfos }
    }

    func appendItinerary(noteID: String, markdown: String, places: [Place]) {
        updateNote(noteID) { note in
            note.markdown += markdown
            note.blocks = nil
            for place in places where !note.places.contains(where: { $0.id == place.id }) {
                note.places.append(place)
            }
        }
    }

    func updatePlaceNote(noteID: String, placeID: String, noteText: String) {
        updateNote(noteID) { note in
            guard let idx = note.places.firstIndex(where: { $0.id == placeID }) else { return }
            note.places[idx].note = noteText
        }
    }

    func setMapEngine(_ engine: MapEngineType) {
        guard AppConfig.load().mapDataInterfaceEnabled else {
            mapEngineError = "请先在首页设置中启用“地图数据接口实验项”"
            return
        }
        guard isMapEngineAvailable(engine) else {
            mapEngineError = engine == .google ? "未配置 Google Maps API Key" : "未配置高德 API Key"
            return
        }
        mapEngineType = engine
        UserDefaults.standard.set(engine.rawValue, forKey: mapEngineTypeKey)
        mapEngineError = nil
        Task {
            await switchMapEngine(engine)
        }
    }

    func updateMapSettings(_ mutate: (inout MapSettings) -> Void) {
        mutate(&mapSettings)
        if let data = try? JSONEncoder().encode(mapSettings) {
            UserDefaults.standard.set(data, forKey: mapSettingKey)
        }
    }

    func chatMessages(for noteID: String) -> [ChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: "ai_chat_\(noteID)"),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return [] }
        return messages
    }

    func saveChatMessages(_ messages: [ChatMessage], noteID: String) {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: "ai_chat_\(noteID)")
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: notesKey) {
            do {
                notes = try JSONDecoder().decode([Note].self, from: data)
                for note in notes {
                    print("[NoteStore] load: note \(note.id) blocks=\(note.blocks?.count ?? -1) md=\(note.markdown.prefix(30))…")
                }
            } catch {
                print("[NoteStore] load: DECODING FAILED – \(error)")
            }
        } else {
            print("[NoteStore] load: no data in UserDefaults")
        }

        if let raw = UserDefaults.standard.string(forKey: mapEngineTypeKey),
           let type = MapEngineType(rawValue: raw) {
            mapEngineType = type
        }

        if let settingsData = UserDefaults.standard.data(forKey: mapSettingKey),
           let decodedSettings = try? JSONDecoder().decode(MapSettings.self, from: settingsData) {
            mapSettings = decodedSettings
        }

        migrateLegacyBlocksIfNeeded()
    }

    private func hasKey(for type: MapEngineType) -> Bool {
        isMapEngineAvailable(type)
    }

    func initializeMapEngine() async {
        do {
            try await nativeEngine.loadScript()
        } catch {
            mapEngineError = "MapKit 本地引擎初始化失败：\(error.localizedDescription)"
            return
        }

        guard AppConfig.load().mapDataInterfaceEnabled else {
            mapEngineError = nil
            return
        }

        if hasKey(for: mapEngineType) {
            do {
                try await remoteEngine(for: mapEngineType).loadScript()
                mapEngineError = nil
            } catch {
                mapEngineError = error.localizedDescription
            }
        } else {
            if hasGoogleMapKey {
                mapEngineType = .google
                UserDefaults.standard.set(MapEngineType.google.rawValue, forKey: mapEngineTypeKey)
            } else if hasAmapMapKey {
                mapEngineType = .amap
                UserDefaults.standard.set(MapEngineType.amap.rawValue, forKey: mapEngineTypeKey)
            }
            mapEngineError = nil
        }
    }

    func switchMapEngine(_ target: MapEngineType) async {
        do {
            try await remoteEngine(for: target).loadScript()
            mapEngineError = nil
        } catch {
            mapEngineError = error.localizedDescription
        }
    }

    func remoteEngine(for type: MapEngineType) -> MapEngine {
        type == .google ? googleEngine : amapEngine
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            UserDefaults.standard.set(data, forKey: notesKey)
            print("[NoteStore] save: wrote \(data.count) bytes to UserDefaults")
        } catch {
            print("[NoteStore] save: ENCODING FAILED – \(error)")
        }
    }

    private func migrateLegacyBlocksIfNeeded() {
        guard let raw = UserDefaults.standard.array(forKey: notesKey) as? [[String: Any]] else { return }
        var migratedAny = false
        for item in raw {
            guard let id = item["id"] as? String,
                  let blocks = item["blocks"] as? [[String: Any]],
                  !notes.contains(where: { $0.id == id })
            else { continue }
            var markdown = ""
            for block in blocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let content = block["content"] as? String {
                    markdown += "\(content)\n\n"
                } else if type == "place",
                          let name = block["name"] as? String,
                          let placeId = block["placeId"] as? String {
                    markdown += "::place[\(name)]{#\(placeId)}\n\n"
                }
            }
            let note = Note(id: id, title: (item["title"] as? String) ?? "未命名笔记", markdown: markdown)
            notes.append(note)
            migratedAny = true
        }
        if migratedAny { save() }
    }
}
