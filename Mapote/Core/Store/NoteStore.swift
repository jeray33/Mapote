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
    @Published var isCloudSyncing = false
    @Published var cloudSyncError: String?
    @Published var lastCloudSyncAt: Date?

    let nativeEngine = NativeMapEngine(type: .google)
    let googleEngine = GoogleMapEngine()
    let amapEngine = AmapMapEngine()

    private let cloudSyncService = CloudSyncService()
    private var cloudSyncTask: Task<Void, Never>?
    private var deletedNotes: [DeletedNote] = []
    private var mapSettingsUpdatedAt: TimeInterval = 0
    private var needsCloudSyncAfterCurrentRun = false

    private let notesKey = "place-notes"
    private let deletedNotesKey = "place-notes-deleted"
    private let lastCloudSyncAtKey = "place-notes-last-cloud-sync-at"
    private let mapSettingKey = "map-settings"
    private let mapSettingsUpdatedAtKey = "map-settings-updated-at"
    private let mapEngineTypeKey = "map-engine-type"

    init() {
        load()
        Task { await initializeMapEngine() }
        scheduleCloudSync(delay: 0.5)
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
        var note = Note(title: "未命名笔记", markdown: "")
        note.updatedAt = Date().timeIntervalSince1970 * 1000
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        save()
        scheduleCloudSync()
    }

    func delete(noteID: String) {
        let deletedAt = Date().timeIntervalSince1970 * 1000
        notes.removeAll { $0.id == noteID }
        deletedNotes.removeAll { $0.id == noteID }
        deletedNotes.append(DeletedNote(id: noteID, deletedAt: deletedAt))
        if selectedNoteID == noteID {
            selectedNoteID = nil
        }
        save()
        saveDeletedNotes()
        scheduleCloudSync()
    }

    func updateNote(_ noteID: String, mutate: (inout Note) -> Void) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        var nextNotes = notes
        mutate(&nextNotes[idx])
        nextNotes[idx].updatedAt = Date().timeIntervalSince1970 * 1000
        notes = nextNotes
        save()
        scheduleCloudSync()
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
        updateNote(noteID) { note in
            note.blocks = blocks
            note.markdown = markdown
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

    func fillMissingPlaceCoverFromAmap(noteID: String, placeID: String) async {
        guard hasAmapMapKey,
              let place = notes.first(where: { $0.id == noteID })?.places.first(where: { $0.id == placeID }),
              !hasImage(place)
        else { return }

        try? await amapEngine.loadScript()

        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullQuery = [name, address].filter { !$0.isEmpty }.joined(separator: " ")
        let location = LatLng(lat: place.lat, lng: place.lng)
        let searches: [(String, SearchOptions?)] = [
            (name, SearchOptions(locationBias: location, radius: 10_000, city: nil)),
            (fullQuery, SearchOptions(locationBias: location, radius: 10_000, city: nil)),
            (name, nil),
            (fullQuery, nil)
        ].filter { !$0.0.isEmpty }

        var cover: String?
        for search in searches {
            let results = await amapEngine.textSearch(query: search.0, options: search.1)
            cover = await firstPhotoURL(from: results)
            if cover != nil {
                break
            }
        }
        guard let cover,
              !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            print("[AmapPhoto] no photo for \(name) / \(address)")
            return
        }

        updateNote(noteID) { note in
            guard let idx = note.places.firstIndex(where: { $0.id == placeID }),
                  !hasImage(note.places[idx])
            else { return }
            note.places[idx].image = cover
            note.places[idx].images = [cover]
            print("[AmapPhoto] filled cover for \(note.places[idx].name): \(cover)")
        }
    }

    func fillMissingPlaceCoversFromAmap(noteID: String) async {
        guard hasAmapMapKey,
              let note = notes.first(where: { $0.id == noteID })
        else { return }

        let missingIDs = note.places
            .filter { !hasImage($0) }
            .map(\.id)
        for placeID in missingIDs {
            await fillMissingPlaceCoverFromAmap(noteID: noteID, placeID: placeID)
        }
    }

    private func firstPhotoURL(from results: [MapPlace]) async -> String? {
        for place in results {
            if let cover = place.photoUrl ?? place.photoUrls?.first,
               !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cover
            }
        }

        for place in results {
            guard let placeId = place.placeId,
                  let details = await amapEngine.getPlaceDetails(placeId: placeId, fields: nil),
                  let cover = details.photoUrl ?? details.photoUrls?.first,
                  !cover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return cover
        }
        return nil
    }

    private func hasImage(_ place: Place) -> Bool {
        if let image = place.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            return true
        }
        return place.images?.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
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
        // Stable core mode: MapKit / NativeMapEngine is the only active engine.
        // Google and Amap integrations are paused to reduce configuration and
        // persistence side effects while the editor is stabilized.
        mapEngineType = engine
        mapEngineError = nil
    }

    func updateMapSettings(_ mutate: (inout MapSettings) -> Void) {
        mutate(&mapSettings)
        mapSettingsUpdatedAt = Date().timeIntervalSince1970 * 1000
        saveMapSettings()
        scheduleCloudSync()
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
            notes = (try? JSONDecoder().decode([Note].self, from: data)) ?? []
        }

        if let deletedData = UserDefaults.standard.data(forKey: deletedNotesKey) {
            deletedNotes = (try? JSONDecoder().decode([DeletedNote].self, from: deletedData)) ?? []
        }

        let lastSyncTime = UserDefaults.standard.double(forKey: lastCloudSyncAtKey)
        if lastSyncTime > 0 {
            lastCloudSyncAt = Date(timeIntervalSince1970: lastSyncTime)
        }

        if let raw = UserDefaults.standard.string(forKey: mapEngineTypeKey),
           let type = MapEngineType(rawValue: raw) {
            mapEngineType = type
        }

        if let settingsData = UserDefaults.standard.data(forKey: mapSettingKey),
           let decodedSettings = try? JSONDecoder().decode(MapSettings.self, from: settingsData) {
            mapSettings = decodedSettings
        }
        mapSettingsUpdatedAt = UserDefaults.standard.double(forKey: mapSettingsUpdatedAtKey)
        if mapSettingsUpdatedAt == 0, UserDefaults.standard.data(forKey: mapSettingKey) != nil {
            mapSettingsUpdatedAt = Date().timeIntervalSince1970 * 1000
            UserDefaults.standard.set(mapSettingsUpdatedAt, forKey: mapSettingsUpdatedAtKey)
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
        mapEngineError = nil
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

    private func saveDeletedNotes() {
        do {
            let data = try JSONEncoder().encode(deletedNotes)
            UserDefaults.standard.set(data, forKey: deletedNotesKey)
        } catch {
            print("[NoteStore] saveDeletedNotes: ENCODING FAILED – \(error)")
        }
    }

    private func saveMapSettings() {
        if let data = try? JSONEncoder().encode(mapSettings) {
            UserDefaults.standard.set(data, forKey: mapSettingKey)
            UserDefaults.standard.set(mapSettingsUpdatedAt, forKey: mapSettingsUpdatedAtKey)
        }
    }

    private func scheduleCloudSync(delay: TimeInterval = 1.5) {
        if isCloudSyncing {
            needsCloudSyncAfterCurrentRun = true
            return
        }

        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.syncWithiCloud()
        }
    }

    func syncWithiCloud() async {
        guard !isCloudSyncing else {
            needsCloudSyncAfterCurrentRun = true
            return
        }

        isCloudSyncing = true
        defer {
            isCloudSyncing = false
            if needsCloudSyncAfterCurrentRun {
                needsCloudSyncAfterCurrentRun = false
                Task { [weak self] in
                    await self?.syncWithiCloud()
                }
            }
        }

        do {
            let snapshot = try await cloudSyncService.synchronize(
                localNotes: notes,
                deletedNotes: deletedNotes,
                mapSettings: mapSettings,
                mapSettingsUpdatedAt: mapSettingsUpdatedAt
            )
            let resolvedSnapshot = mergeCloudSnapshotWithCurrentLocalChanges(snapshot)
            notes = resolvedSnapshot.notes
            deletedNotes = resolvedSnapshot.deletedNotes
            mapSettings = resolvedSnapshot.mapSettings
            mapSettingsUpdatedAt = resolvedSnapshot.mapSettingsUpdatedAt
            save()
            saveDeletedNotes()
            saveMapSettings()
            lastCloudSyncAt = Date()
            if let lastCloudSyncAt {
                UserDefaults.standard.set(lastCloudSyncAt.timeIntervalSince1970, forKey: lastCloudSyncAtKey)
            }
            cloudSyncError = nil
            print("[iCloudSync] synced \(notes.count) notes, \(deletedNotes.count) tombstones")
        } catch {
            cloudSyncError = CloudSyncService.displayMessage(for: error)
            print("[iCloudSync] skipped/failed: \(cloudSyncError ?? error.localizedDescription)")
        }
    }

    private func mergeCloudSnapshotWithCurrentLocalChanges(_ snapshot: CloudSyncSnapshot) -> CloudSyncSnapshot {
        var notesByID = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
        var deletedByID = Dictionary(uniqueKeysWithValues: snapshot.deletedNotes.map { ($0.id, $0) })

        for localDeleted in deletedNotes {
            let cloudDeletedAt = deletedByID[localDeleted.id]?.deletedAt ?? 0
            if localDeleted.deletedAt > cloudDeletedAt {
                deletedByID[localDeleted.id] = localDeleted
            }
        }

        for localNote in notes {
            if let deletedAt = deletedByID[localNote.id]?.deletedAt,
               deletedAt >= localNote.updatedAt {
                continue
            }

            if let cloudNote = notesByID[localNote.id] {
                if localNote.updatedAt >= cloudNote.updatedAt {
                    notesByID[localNote.id] = localNote
                }
            } else {
                notesByID[localNote.id] = localNote
            }
        }

        for deleted in deletedByID.values {
            if let note = notesByID[deleted.id], deleted.deletedAt >= note.updatedAt {
                notesByID.removeValue(forKey: deleted.id)
            }
        }

        let mergedNotes = notesByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
        let mergedDeletedNotes = deletedByID.values.sorted { $0.deletedAt > $1.deletedAt }

        if mapSettingsUpdatedAt > snapshot.mapSettingsUpdatedAt {
            return CloudSyncSnapshot(
                notes: mergedNotes,
                deletedNotes: mergedDeletedNotes,
                mapSettings: mapSettings,
                mapSettingsUpdatedAt: mapSettingsUpdatedAt
            )
        }

        return CloudSyncSnapshot(
            notes: mergedNotes,
            deletedNotes: mergedDeletedNotes,
            mapSettings: snapshot.mapSettings,
            mapSettingsUpdatedAt: snapshot.mapSettingsUpdatedAt
        )
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
