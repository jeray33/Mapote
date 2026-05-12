import SwiftUI
import UIKit

struct EditModeView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String
    @Binding var isLocked: Bool

    @State private var editorText: String = ""
    @State private var mentionQuery: String = ""
    @State private var mentionResults: [MapPlace] = []
    @State private var insertCommand: EditorInsertCommand?
    @State private var placeInsertionRequest: PlaceInsertionRequest?
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
        }
        .onChange(of: note?.markdown) { _, newValue in
            guard let newValue, newValue != editorText else { return }
            editorText = newValue
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
                insertCommand: $insertCommand,
                placeInsertionRequest: $placeInsertionRequest,
                loadErrorMessage: $loadErrorMessage,
                places: note?.places ?? [],
                isLocked: isLocked,
                onFocusChange: { focused = $0 },
                onMentionCheck: { text, context in handleMention(text, context: context) },
                onTapPlace: { placeID in
                    guard let place = note?.places.first(where: { $0.id == placeID || $0.placeId == placeID }) else { return }
                    selectedPlace = place
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
        .padding(.horizontal, 16)
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
            HStack(spacing: 10) {
                toolbarButton("撤销", systemImage: "arrow.uturn.backward", command: .undo)
                toolbarButton("重做", systemImage: "arrow.uturn.forward", command: .redo)
                toolbarButton("@地点", systemImage: "at", command: .insertText("@"))
                toolbarButton("粗体", systemImage: "bold", command: .toggleBold)
                toolbarButton("H1", systemImage: "textformat.size.larger", command: .heading(1))
                toolbarButton("H2", systemImage: "textformat", command: .heading(2))
                toolbarButton("H3", systemImage: "textformat.size.smaller", command: .heading(3))
                toolbarButton("无序", systemImage: "list.bullet", command: .bulletList)
                toolbarButton("有序", systemImage: "list.number", command: .orderedList)
                toolbarButton("任务", systemImage: "checklist", command: .taskList)
                toolbarButton("分割", systemImage: "minus", command: .divider)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func toolbarButton(_ title: String, systemImage: String, command: EditorCommandKind) -> some View {
        Button {
            insertCommand = EditorInsertCommand(kind: command)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppTheme.foreground)
            .frame(width: 44, height: 44)
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

