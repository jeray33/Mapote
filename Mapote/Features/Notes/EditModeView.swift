import SwiftUI
import UIKit
import PhotosUI

struct EditModeView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String
    @Binding var isLocked: Bool

    @State private var editorText: String = ""
    @State private var editorBlocks: Data?
    @State private var mentionQuery: String = ""
    @State private var mentionResults: [MapPlace] = []
    @State private var insertCommand: EditorInsertCommand?
    @State private var placeInsertionRequest: PlaceInsertionRequest?
    @State private var imageInsertion: EditorImageInsertion?
    @State private var imagePickerRequest: UUID?
    @State private var imagePickerVisible = false
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var loadErrorMessage: String?
    @State private var selectedPlace: Place?
    @State private var mentionRect: CGRect?
    @FocusState private var focused: Bool
    @State private var isKeyboardVisible = false

    private var note: Note? {
        store.notes.first(where: { $0.id == noteID })
    }

    var body: some View {
        editor
            .safeAreaInset(edge: .bottom) {
                if !isLocked, isKeyboardVisible {
                    toolbar
                        .background(AppTheme.card)
                }
            }
        .onAppear {
            editorText = note?.markdown ?? ""
            editorBlocks = note?.blocks
        }
        .onChange(of: note?.markdown) { _, newValue in
            guard let newValue, newValue != editorText else { return }
            editorText = newValue
        }
        .onChange(of: note?.blocks) { _, newValue in
            guard newValue != editorBlocks else { return }
            editorBlocks = newValue
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailSheet(
                place: place,
                isLocked: isLocked,
                onDelete: {
                    store.removePlace(noteID: noteID, placeID: place.id)
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: imagePickerRequest) { _, newValue in
            guard newValue != nil else { return }
            imagePickerVisible = true
        }
        .photosPicker(
            isPresented: $imagePickerVisible,
            selection: $pickedPhotoItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedPhoto(newItem) }
        }
    }

    private func handlePickedPhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhotoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                return
            }
            let ext = inferImageExtension(from: data, fallback: "jpg")
            guard let url = EditorImageStorage.save(data, ext: ext) else { return }
            await MainActor.run {
                imageInsertion = EditorImageInsertion(url: url)
            }
        } catch {
            // Silently ignore picker errors; user can retry.
        }
    }

    private func inferImageExtension(from data: Data, fallback: String) -> String {
        // Sniff the first few bytes for common image magic numbers.
        let header = data.prefix(12)
        let bytes = [UInt8](header)
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        // HEIC: "ftypheic" / "ftypheix" / "ftypmif1" near byte 4
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "heic"
        }
        return fallback
    }

    private var editor: some View {
        VStack(spacing: 10) {
            TiptapEditorView(
                markdown: Binding(
                    get: { editorText },
                    set: { value in
                        editorText = value
                        store.updateMarkdown(noteID: noteID, markdown: value)
                    }
                ),
                blocks: Binding(
                    get: { editorBlocks },
                    set: { editorBlocks = $0 }
                ),
                insertCommand: $insertCommand,
                placeInsertionRequest: $placeInsertionRequest,
                imageInsertion: $imageInsertion,
                imagePickerRequest: $imagePickerRequest,
                loadErrorMessage: $loadErrorMessage,
                places: note?.places ?? [],
                isLocked: isLocked,
                onFocusChange: { focused = $0 },
                onMentionCheck: { text, context in handleMention(text, context: context) },
                onTapPlace: { placeID in
                    guard let place = note?.places.first(where: { $0.id == placeID || $0.placeId == placeID }) else { return }
                    selectedPlace = place
                },
                onBlocksUpdate: { blocks, markdown in
                    editorBlocks = blocks
                    editorText = markdown
                    store.updateBlocks(noteID: noteID, blocks: blocks, markdown: markdown)
                }
            )
            .frame(maxHeight: .infinity)
            .background(Color.clear)

            if let loadErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadErrorMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.foregroundSoft)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.paper.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .overlay(alignment: .topLeading) {
            if !mentionResults.isEmpty {
                mentionDropdown
                    .frame(maxWidth: 320)
                    .offset(x: mentionOffsetX, y: mentionOffsetY)
            }
        }
    }

    private var mentionOffsetX: CGFloat {
        max((mentionRect?.minX ?? 0) - 8, 8)
    }

    private var mentionOffsetY: CGFloat {
        max((mentionRect?.maxY ?? 0) + 14, 16)
    }

    private var mentionDropdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mentionQuery.isEmpty ? "笔记中的地点" : "搜索结果")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.foregroundSoft)
                .padding(.horizontal, 4)
            ForEach(mentionResults, id: \.id) { item in
                Button {
                    addMentionResult(item)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.subheadline.weight(.semibold))
                        Text(item.address).font(.caption).foregroundStyle(AppTheme.foregroundSoft).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: AppTheme.shadow, radius: 10, y: 6)
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                toolbarIconButton(systemImage: "arrow.uturn.backward", command: .undo)
                toolbarIconButton(systemImage: "arrow.uturn.forward", command: .redo)
                toolbarIconButton(systemImage: "at", command: .insertText("@"))
                toolbarIconButton(systemImage: "bold", command: .toggleBold)
                toolbarTextButton("H1", command: .heading(1))
                toolbarTextButton("H2", command: .heading(2))
                toolbarTextButton("H3", command: .heading(3))
                toolbarIconButton(systemImage: "list.bullet", command: .bulletList)
                toolbarIconButton(systemImage: "list.number", command: .orderedList)
                toolbarIconButton(systemImage: "checklist", command: .taskList)
                toolbarIconButton(systemImage: "minus", command: .divider)
                imageToolbarButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var imageToolbarButton: some View {
        toolbarShell {
            imagePickerVisible = true
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 17, weight: .medium))
        }
    }

    private func toolbarIconButton(systemImage: String, command: EditorCommandKind) -> some View {
        toolbarShell {
            insertCommand = EditorInsertCommand(kind: command)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
    }

    private func toolbarTextButton(_ text: String, command: EditorCommandKind) -> some View {
        toolbarShell {
            insertCommand = EditorInsertCommand(kind: command)
        } label: {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func toolbarShell<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 36, height: 30)
        }
        .buttonStyle(.plain)
    }

    private func handleMention(_ text: String, context: TiptapEditorView.MentionContext?) {
        guard let context else {
            mentionResults = []
            mentionRect = nil
            return
        }
        mentionQuery = context.query
        mentionRect = context.rect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        Task {
            if context.query.isEmpty {
                let local = (note?.places ?? []).prefix(5).map {
                    MapPlace(
                        name: $0.name,
                        address: $0.address,
                        lat: $0.lat,
                        lng: $0.lng,
                        placeId: $0.placeId ?? $0.id,
                        photoUrl: $0.image,
                        photoUrls: $0.images,
                        types: $0.types,
                        rating: $0.rating,
                        openingHours: $0.openingHours,
                        editorialSummary: $0.description,
                        reviews: nil,
                        openNow: $0.openNow
                    )
                }
                await MainActor.run { mentionResults = Array(local) }
            } else {
                let location = note?.places.averageLatLng
                let results = await store.currentEngine.textSearch(
                    query: context.query,
                    options: SearchOptions(locationBias: location, radius: 50000, city: nil)
                )
                await MainActor.run { mentionResults = Array(results.prefix(5)) }
            }
        }
    }

    private func addMentionResult(_ mapPlace: MapPlace) {
        let place = Place(
            name: mapPlace.name,
            address: mapPlace.address,
            lat: mapPlace.lat,
            lng: mapPlace.lng,
            image: mapPlace.photoUrl,
            images: mapPlace.photoUrls,
            placeId: mapPlace.placeId,
            description: mapPlace.editorialSummary,
            openingHours: mapPlace.openingHours,
            category: PlaceCategory.infer(from: mapPlace.types),
            types: mapPlace.types,
            rating: mapPlace.rating,
            openNow: mapPlace.openNow
        )
        mentionResults = []
        mentionRect = nil
        store.updateNote(noteID) { note in
            if !note.places.contains(where: { $0.id == place.id }) {
                note.places.append(place)
            }
        }
        placeInsertionRequest = PlaceInsertionRequest(place: place)
    }
}

struct PlaceDetailSheet: View {
    let place: Place
    let isLocked: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaceImageCarouselView(
                imageURLs: place.images ?? (place.image.map { [$0] } ?? []),
                height: 160
            )

            Text(place.name).font(.title3.bold())
            Text(place.address).font(.subheadline).foregroundStyle(.secondary)
            if !place.note.isEmpty {
                Text(place.note).font(.body)
            }
            if let rating = place.rating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
            }
            if let openNow = place.openNow {
                Text(openNow ? "营业中" : "已关闭")
                    .font(.caption)
                    .foregroundStyle(openNow ? .green : .red)
            }
            if let openingHours = place.openingHours {
                VStack(alignment: .leading, spacing: 4) {
                    Text("营业时间").font(.subheadline.bold())
                    ForEach(openingHours, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("导航到此地点") {
                    let lat = place.lat
                    let lng = place.lng
                    if let url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)") {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.mapotePrimary)

                if !isLocked {
                    Button("删除此地点", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                    .buttonStyle(.mapoteDanger)
                }
            }
        }
        .padding(16)
        .presentationDetents([.medium, .large])
    }
}

struct ImportPlacesSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let noteID: String

    @State private var inputText = ""
    @State private var extracted: [AIExtractPlace] = []
    @State private var matches: [String: MapPlace] = [:]
    @State private var selectedIDs: Set<String> = []
    @State private var region: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if extracted.isEmpty {
                    TextEditor(text: $inputText)
                        .frame(maxHeight: .infinity)
                        .padding(10)
                        .background(AppTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("智能识别地点") {
                        Task { await identifyPlaces() }
                    }
                    .buttonStyle(.mapotePrimary)
                    .disabled(loading || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    List {
                        ForEach(extracted, id: \.name) { item in
                            HStack {
                                Image(systemName: selectedIDs.contains(item.name) ? "checkmark.circle.fill" : "circle")
                                    .onTapGesture {
                                        if selectedIDs.contains(item.name) { selectedIDs.remove(item.name) } else { selectedIDs.insert(item.name) }
                                    }
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if let matched = matches[item.name] {
                                        Text(matched.address).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("未找到匹配地点").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    HStack {
                        Button("全选") { selectedIDs = Set(extracted.map(\.name)) }
                        Button("取消全选") { selectedIDs = [] }
                        Spacer()
                        Button("加入笔记 (\(selectedIDs.count))") {
                            addSelected()
                        }
                        .buttonStyle(.mapotePrimary)
                        .disabled(selectedIDs.isEmpty)
                    }
                }
            }
            .padding(16)
            .navigationTitle("导入地点")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func identifyPlaces() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await GeminiService.shared.extractPlaces(from: inputText)
            let filtered = AIParsingService.filterBroadNames(result.places)
            extracted = filtered
            selectedIDs = Set(filtered.map(\.name))
            region = result.region

            var bias: LatLng?
            for item in filtered {
                if let found = await store.currentEngine.findPlace(
                    query: item.searchQuery,
                    options: SearchOptions(locationBias: bias, radius: 50000, city: region)
                ) {
                    matches[item.name] = found
                    if bias == nil { bias = LatLng(lat: found.lat, lng: found.lng) }
                }
            }
        } catch {
            extracted = []
        }
    }

    private func addSelected() {
        var markdown = ""
        var places: [Place] = []
        for item in extracted where selectedIDs.contains(item.name) {
            guard let hit = matches[item.name] else { continue }
            let place = Place(
                name: item.name,
                address: hit.address,
                lat: hit.lat,
                lng: hit.lng,
                image: hit.photoUrl,
                images: hit.photoUrls,
                placeId: hit.placeId,
                description: hit.editorialSummary,
                openingHours: hit.openingHours,
                category: PlaceCategory.infer(from: hit.types),
                types: hit.types,
                rating: hit.rating,
                openNow: hit.openNow
            )
            markdown += "\n::place[\(place.name)]{#\(place.id)}"
            places.append(place)
        }
        store.appendItinerary(noteID: noteID, markdown: markdown, places: places)
        dismiss()
    }
}

