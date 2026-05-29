import CloudKit
import Foundation

struct CloudSyncSnapshot {
    var notes: [Note]
    var deletedNotes: [DeletedNote]
    var mapSettings: MapSettings = .init()
    var mapSettingsUpdatedAt: TimeInterval = 0
}

final class CloudSyncService {
    private enum Field {
        static let noteID = "mnNoteID"
        static let title = "mnTitle"
        static let updatedAt = "mnUpdatedAt"
        static let deletedAt = "mnDeletedAt"
        static let payloadAsset = "mnPayloadAsset"

        static let legacyNoteID = "noteID"
        static let legacyUpdatedAt = "updatedAt"
        static let legacyDeletedAt = "deletedAt"
        static let legacyPayloadData = "payload"
        static let legacyPayloadAsset = "payloadAsset"
    }

    private enum ImageField {
        static let filename = "miFilename"
        static let updatedAt = "miUpdatedAt"
        static let asset = "miAsset"
    }

    private enum SettingsField {
        static let updatedAt = "msUpdatedAt"
        static let payloadText = "msPayloadText"

        static let legacyPayload = "payload"
        static let payload = "settingsPayload"
    }

    private enum ManifestField {
        static let noteIDsText = "mmNoteIDsText"
        static let updatedAt = "mmUpdatedAt"
    }

    private enum DeletedNoteField {
        static let noteID = "mdNoteID"
        static let deletedAt = "mdDeletedAt"
    }

    private struct RemoteNoteRecord {
        var id: String
        var note: Note?
        var updatedAt: TimeInterval
        var deletedAt: TimeInterval?
    }

    private let container = CKContainer(identifier: "iCloud.innervision.Mapote")
    private let noteRecordType = "MapoteNote"
    private let deletedNoteRecordType = "MapoteDeletedNote"
    private let imageRecordType = "MapoteEditorImage"
    private let settingsRecordType = "MapoteUserSettings"
    private let manifestRecordType = "MapoteManifest"
    private let databaseSubscriptionID = "mapote-private-database-changes"

    static func displayMessage(for error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        var parts = ["CloudKit \(ckError.code): \(ckError.localizedDescription)"]
        if let serverMessage = ckError.userInfo["ServerErrorDescription"] as? String {
            parts.append(serverMessage)
        }
        if let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partialErrors.isEmpty {
            for (item, partialError) in partialErrors {
                parts.append("\(item): \(displayMessage(for: partialError))")
            }
        }
        if let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            parts.append("建议 \(Int(retryAfter)) 秒后重试")
        }
        return parts.joined(separator: "\n")
    }

    func synchronize(
        localNotes: [Note],
        deletedNotes: [DeletedNote],
        mapSettings: MapSettings,
        mapSettingsUpdatedAt: TimeInterval
    ) async throws -> CloudSyncSnapshot {
        try await ensureAccountAvailable()
        await ensureDatabaseSubscriptionIfPossible()

        let remoteRecords = try await perform("拉取笔记") {
            try await fetchRemoteNotes(
                localNoteIDs: Set(localNotes.map(\.id)),
                deletedNoteIDs: Set(deletedNotes.map(\.id))
            )
        }
        let mergedNotes = merge(localNotes: localNotes, deletedNotes: deletedNotes, remoteRecords: remoteRecords)
        let mergedSettings = try await perform("拉取设置") {
            try await mergeMapSettings(
                localSettings: mapSettings,
                localUpdatedAt: mapSettingsUpdatedAt
            )
        }

        try await perform("上传笔记") {
            try await upload(notes: mergedNotes.notes)
        }
        await uploadDeletedNotesIfPossible(deletedNotes: mergedNotes.deletedNotes)
        await uploadManifestIfPossible(notes: mergedNotes.notes, deletedNotes: mergedNotes.deletedNotes)
        await uploadMapSettingsIfPossible(settings: mergedSettings.settings, updatedAt: mergedSettings.updatedAt)
        try await perform("同步编辑器图片") {
            try await synchronizeEditorImages(for: mergedNotes.notes)
        }

        return CloudSyncSnapshot(
            notes: mergedNotes.notes,
            deletedNotes: mergedNotes.deletedNotes,
            mapSettings: mergedSettings.settings,
            mapSettingsUpdatedAt: mergedSettings.updatedAt
        )
    }

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    private func perform<T>(_ stage: String, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw NSError(
                domain: "CloudSyncService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(stage)失败：\(Self.displayMessage(for: error))"]
            )
        }
    }

    private func ensureAccountAvailable() async throws {
        let status: CKAccountStatus = try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }

        guard status == .available else {
            throw NSError(
                domain: "CloudSyncService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "iCloud account is not available"]
            )
        }
    }

    private func ensureDatabaseSubscriptionIfPossible() async {
        do {
            guard try await existingSubscription(id: databaseSubscriptionID) == nil else { return }

            let subscription = CKDatabaseSubscription(subscriptionID: databaseSubscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo
            try await save(subscription)
        } catch {
            print("[iCloudSync] database subscription unavailable: \(error.localizedDescription)")
        }
    }

    private func existingSubscription(id: String) async throws -> CKSubscription? {
        do {
            return try await database.subscription(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func fetchRemoteNotes(localNoteIDs: Set<String>, deletedNoteIDs: Set<String>) async throws -> [RemoteNoteRecord] {
        let manifestNoteIDs = try await fetchManifestNoteIDs()
        let noteIDs = manifestNoteIDs.union(localNoteIDs).union(deletedNoteIDs)
        guard !noteIDs.isEmpty else { return [] }

        var remoteRecords: [RemoteNoteRecord] = []
        for noteID in noteIDs {
            if let record = try await optionalExistingRecord(recordID: noteRecordID(for: noteID)),
               let remoteRecord = remoteRecord(from: record) {
                remoteRecords.append(remoteRecord)
            }
            if let deletedRecord = try await optionalExistingRecord(recordID: deletedNoteRecordID(for: noteID)),
               let deletedRemoteRecord = deletedRemoteRecord(from: deletedRecord) {
                remoteRecords.append(deletedRemoteRecord)
            }
        }
        return remoteRecords
    }

    private func remoteRecord(from record: CKRecord) -> RemoteNoteRecord? {
        guard let id = record[Field.noteID] as? String ?? record[Field.legacyNoteID] as? String else { return nil }
        let updatedAt = (record[Field.updatedAt] as? NSNumber)?.doubleValue
            ?? (record[Field.legacyUpdatedAt] as? NSNumber)?.doubleValue
            ?? 0
        let deletedAt = (record[Field.deletedAt] as? NSNumber)?.doubleValue
            ?? (record[Field.legacyDeletedAt] as? NSNumber)?.doubleValue

        if let deletedAt {
            return RemoteNoteRecord(id: id, note: nil, updatedAt: updatedAt, deletedAt: deletedAt)
        }

        guard let note = decodeNote(from: record) else { return nil }
        return RemoteNoteRecord(id: id, note: note, updatedAt: note.updatedAt, deletedAt: nil)
    }

    private func deletedRemoteRecord(from record: CKRecord) -> RemoteNoteRecord? {
        guard let id = record[DeletedNoteField.noteID] as? String else { return nil }
        let deletedAt = (record[DeletedNoteField.deletedAt] as? NSNumber)?.doubleValue ?? 0
        guard deletedAt > 0 else { return nil }
        return RemoteNoteRecord(id: id, note: nil, updatedAt: deletedAt, deletedAt: deletedAt)
    }

    private func decodeNote(from record: CKRecord) -> Note? {
        if let asset = record[Field.payloadAsset] as? CKAsset,
           let fileURL = asset.fileURL,
           let data = try? Data(contentsOf: fileURL) {
            return try? JSONDecoder().decode(Note.self, from: data)
        }

        if let asset = record[Field.legacyPayloadAsset] as? CKAsset,
           let fileURL = asset.fileURL,
           let data = try? Data(contentsOf: fileURL) {
            return try? JSONDecoder().decode(Note.self, from: data)
        }

        if let data = record[Field.legacyPayloadData] as? Data {
            return try? JSONDecoder().decode(Note.self, from: data)
        }

        return nil
    }

    private func merge(
        localNotes: [Note],
        deletedNotes: [DeletedNote],
        remoteRecords: [RemoteNoteRecord]
    ) -> CloudSyncSnapshot {
        var notesByID = Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id, $0) })
        var deletedByID = Dictionary(uniqueKeysWithValues: deletedNotes.map { ($0.id, $0) })

        for record in remoteRecords {
            if let remoteDeletedAt = record.deletedAt {
                let localDeletedAt = deletedByID[record.id]?.deletedAt ?? 0
                if remoteDeletedAt > localDeletedAt {
                    deletedByID[record.id] = DeletedNote(id: record.id, deletedAt: remoteDeletedAt)
                }
                if let localNote = notesByID[record.id], remoteDeletedAt >= localNote.updatedAt {
                    notesByID.removeValue(forKey: record.id)
                }
                continue
            }

            guard let remoteNote = record.note else { continue }
            if let deletedAt = deletedByID[remoteNote.id]?.deletedAt, deletedAt >= remoteNote.updatedAt {
                continue
            }

            if let localNote = notesByID[remoteNote.id] {
                if remoteNote.updatedAt > localNote.updatedAt {
                    notesByID[remoteNote.id] = remoteNote
                }
            } else {
                notesByID[remoteNote.id] = remoteNote
            }
        }

        for deleted in deletedByID.values {
            if let note = notesByID[deleted.id], deleted.deletedAt >= note.updatedAt {
                notesByID.removeValue(forKey: deleted.id)
            }
        }

        let notes = notesByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
        let deleted = deletedByID.values.sorted { $0.deletedAt > $1.deletedAt }
        return CloudSyncSnapshot(notes: notes, deletedNotes: deleted)
    }

    private func upload(notes: [Note]) async throws {
        for note in notes {
            let record = try await makeRecord(for: note)
            try await save(record)
        }
    }

    private func upload(deletedNotes: [DeletedNote]) async throws {
        for deletedNote in deletedNotes {
            let record = try await record(
                recordType: deletedNoteRecordType,
                recordID: deletedNoteRecordID(for: deletedNote.id)
            )
            record[DeletedNoteField.noteID] = deletedNote.id as CKRecordValue
            record[DeletedNoteField.deletedAt] = deletedNote.deletedAt as CKRecordValue
            try await save(record)
        }
    }

    private func uploadDeletedNotesIfPossible(deletedNotes: [DeletedNote]) async {
        do {
            try await perform("上传删除记录") {
                try await upload(deletedNotes: deletedNotes)
            }
        } catch {
            print("[iCloudSync] deleted-note upload skipped: \(Self.displayMessage(for: error))")
        }
    }

    private func uploadManifest(notes: [Note], deletedNotes: [DeletedNote]) async throws {
        let noteIDs = Set(notes.map(\.id)).union(deletedNotes.map(\.id)).sorted()
        let record = CKRecord(recordType: manifestRecordType, recordID: manifestRecordID())
        let noteIDsData = try JSONEncoder().encode(noteIDs)
        let noteIDsText = String(data: noteIDsData, encoding: .utf8) ?? "[]"
        record[ManifestField.noteIDsText] = noteIDsText as CKRecordValue
        record[ManifestField.updatedAt] = Date().timeIntervalSince1970 * 1000 as CKRecordValue
        try await save(record)
    }

    private func uploadManifestIfPossible(notes: [Note], deletedNotes: [DeletedNote]) async {
        do {
            try await perform("上传索引") {
                try await uploadManifest(notes: notes, deletedNotes: deletedNotes)
            }
        } catch {
            print("[iCloudSync] manifest upload skipped: \(Self.displayMessage(for: error))")
        }
    }

    private func makeRecord(for note: Note) async throws -> CKRecord {
        let record = CKRecord(recordType: noteRecordType, recordID: noteRecordID(for: note.id))
        let data = try JSONEncoder().encode(note)
        let payloadURL = try payloadFileURL(for: note.id, data: data)
        record[Field.noteID] = note.id as CKRecordValue
        record[Field.title] = note.title as CKRecordValue
        record[Field.updatedAt] = note.updatedAt as CKRecordValue
        record[Field.deletedAt] = nil
        record[Field.payloadAsset] = CKAsset(fileURL: payloadURL)
        return record
    }

    private func payloadFileURL(for noteID: String, data: Data) throws -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("CloudSyncPayloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)

        let fileURL = directory.appendingPathComponent("note_\(noteID).json")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func noteRecordID(for noteID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "mapote_note_\(noteID)")
    }

    private func deletedNoteRecordID(for noteID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "mapote_deleted_note_\(noteID)")
    }

    private func mergeMapSettings(
        localSettings: MapSettings,
        localUpdatedAt: TimeInterval
    ) async throws -> (settings: MapSettings, updatedAt: TimeInterval) {
        guard let remoteRecord = try await optionalExistingRecord(recordID: mapSettingsRecordID()),
              let remoteSettings = decodeMapSettings(from: remoteRecord)
        else { return (localSettings, localUpdatedAt) }

        let remoteUpdatedAt = (remoteRecord[SettingsField.updatedAt] as? NSNumber)?.doubleValue ?? 0
        if remoteUpdatedAt > localUpdatedAt {
            return (remoteSettings, remoteUpdatedAt)
        }
        return (localSettings, localUpdatedAt)
    }

    private func decodeMapSettings(from record: CKRecord) -> MapSettings? {
        if let text = record[SettingsField.payloadText] as? String,
           let data = text.data(using: .utf8) {
            return try? JSONDecoder().decode(MapSettings.self, from: data)
        }
        if let data = record[SettingsField.payload] as? Data {
            return try? JSONDecoder().decode(MapSettings.self, from: data)
        }
        if let data = record[SettingsField.legacyPayload] as? Data {
            return try? JSONDecoder().decode(MapSettings.self, from: data)
        }
        return nil
    }

    private func upload(mapSettings: MapSettings, updatedAt: TimeInterval) async throws {
        let record = CKRecord(recordType: settingsRecordType, recordID: mapSettingsRecordID())
        let settingsData = try JSONEncoder().encode(mapSettings)
        let settingsText = String(data: settingsData, encoding: .utf8) ?? "{}"
        record[SettingsField.updatedAt] = updatedAt as CKRecordValue
        record[SettingsField.payloadText] = settingsText as CKRecordValue
        try await save(record)
    }

    private func uploadMapSettingsIfPossible(settings: MapSettings, updatedAt: TimeInterval) async {
        do {
            try await perform("上传设置") {
                try await upload(mapSettings: settings, updatedAt: updatedAt)
            }
        } catch {
            print("[iCloudSync] settings upload skipped: \(Self.displayMessage(for: error))")
        }
    }

    private func mapSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: "mapote_user_settings")
    }

    private func fetchManifestNoteIDs() async throws -> Set<String> {
        guard let record = try await optionalExistingRecord(recordID: manifestRecordID()),
              let text = record[ManifestField.noteIDsText] as? String,
              let data = text.data(using: .utf8),
              let noteIDs = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(noteIDs)
    }

    private func manifestRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: "mapote_manifest")
    }

    private func synchronizeEditorImages(for notes: [Note]) async throws {
        let filenames = referencedEditorImageFilenames(in: notes)
        guard !filenames.isEmpty else { return }

        try await uploadEditorImages(filenames: filenames)
        try await downloadMissingEditorImages(filenames: filenames)
    }

    private func uploadEditorImages(filenames: Set<String>) async throws {
        for filename in filenames {
            let fileURL = EditorImageStorage.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let record = try await record(
                recordType: imageRecordType,
                recordID: imageRecordID(for: filename)
            )
            record[ImageField.filename] = filename as CKRecordValue
            record[ImageField.updatedAt] = Date().timeIntervalSince1970 * 1000 as CKRecordValue
            record[ImageField.asset] = CKAsset(fileURL: fileURL)
            try await save(record)
        }
    }

    private func downloadMissingEditorImages(filenames: Set<String>) async throws {
        for filename in filenames {
            let destinationURL = EditorImageStorage.directory.appendingPathComponent(filename)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }

            let imageRecordID = imageRecordID(for: filename)
            guard let remoteRecord = try await existingRecord(recordID: imageRecordID),
                  let asset = remoteRecord[ImageField.asset] as? CKAsset,
                  let fileURL = asset.fileURL
            else { continue }

            try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        }
    }

    private func referencedEditorImageFilenames(in notes: [Note]) -> Set<String> {
        var filenames = Set<String>()
        for note in notes {
            insertEditorImageFilenames(from: note.markdown, into: &filenames)
            if let blocks = note.blocks,
               let blocksString = String(data: blocks, encoding: .utf8) {
                insertEditorImageFilenames(from: blocksString, into: &filenames)
            }
        }
        return filenames
    }

    private func insertEditorImageFilenames(from text: String, into filenames: inout Set<String>) {
        let prefix = "\(EditorImageStorage.scheme)://"
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + #"([^\s\)\]\}\"'<>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let filenameRange = Range(match.range(at: 1), in: text)
            else { continue }
            let encodedFilename = String(text[filenameRange])
            let filename = encodedFilename.removingPercentEncoding ?? encodedFilename
            if isSafeEditorImageFilename(filename) {
                filenames.insert(filename)
            }
        }
    }

    private func isSafeEditorImageFilename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.contains("/") && !filename.contains("..")
    }

    private func imageRecordID(for filename: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "mapote_image_\(filename)")
    }

    private func record(recordType: String, recordID: CKRecord.ID) async throws -> CKRecord {
        if let existingRecord = try await existingRecord(recordID: recordID) {
            return existingRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private func existingRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func optionalExistingRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await existingRecord(recordID: recordID)
        } catch let error as CKError where shouldTreatAsMissingRecord(error) {
            return nil
        }
    }

    private func shouldTreatAsMissingRecord(_ error: CKError) -> Bool {
        switch error.code {
        case .unknownItem, .serverRejectedRequest, .invalidArguments:
            return true
        default:
            return false
        }
    }

    private func save(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }

    private func save(_ subscription: CKSubscription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifySubscriptionsOperation(
                subscriptionsToSave: [subscription],
                subscriptionIDsToDelete: nil
            )
            operation.modifySubscriptionsResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }
}
