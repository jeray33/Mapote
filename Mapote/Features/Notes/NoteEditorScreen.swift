import SwiftUI
import UIKit

struct NoteEditorScreen: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String

    @State private var mode: ViewMode = .edit
    @State private var isLocked = false
    @State private var showImportSheet = false
    @State private var showAIChat = false
    @State private var isConverting = false
    @State private var noticeText: String?
    @State private var isKeyboardVisible = false

    private var note: Note? {
        store.notes.first(where: { $0.id == noteID })
    }

    var body: some View {
        if let note {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topNav
                    }
                    .background(AppTheme.background)

                    content(note: note)
                }

                if mode == .edit, !isKeyboardVisible {
                    Button {
                        showAIChat = true
                    } label: {
                        Image(systemName: "message.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(AppTheme.primary)
                            .clipShape(Circle())
                    }
                    .shadow(color: AppTheme.primary.opacity(0.26), radius: 24, y: 12)
                    .padding(.trailing, 22)
                    .padding(.bottom, 10)
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .sheet(isPresented: $showImportSheet) {
                ImportPlacesSheet(noteID: noteID)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showAIChat) {
                AIChatSheet(noteID: noteID)
                    .environmentObject(store)
                    .presentationDetents([.fraction(0.7)])
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
        }
    }

    @ViewBuilder
    private func content(note: Note) -> some View {
        switch mode {
        case .edit:
            VStack(spacing: 0) {
                titleBar(note: note)
                if let noticeText {
                    statusBanner(text: noticeText)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                EditModeView(
                    noteID: noteID,
                    isLocked: $isLocked
                )
                .environmentObject(store)
            }
        case .list:
            ListModeView(noteID: noteID)
                .environmentObject(store)
        case .map:
            MapModeView(noteID: noteID)
                .environmentObject(store)
        }
    }

    private var topNav: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.select(noteID: nil)
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回笔记列表")

                HStack(spacing: 6) {
                    modeButton(.edit, systemImage: "pencil")
                    modeButton(.list, systemImage: "list.bullet")
                    modeButton(.map, systemImage: "map")
                }
                .padding(2)
                .background(AppTheme.muted)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            Divider()
        }
    }

    private func titleBar(note: Note) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("笔记标题", text: Binding(
                get: { note.title },
                set: { store.updateTitle(noteID: noteID, title: $0) }
            ))
            .font(.largeTitle.weight(.bold))
            .textFieldStyle(.plain)
            .foregroundStyle(AppTheme.foreground)
            .disabled(isLocked)

            HStack(spacing: 2) {
                Button {
                    Task { await oneClickConvert() }
                } label: {
                    toolbarIcon(isConverting ? "progress.indicator" : "sparkles")
                }
                .disabled(isConverting || isLocked)
                .accessibilityLabel("智能转换地点")
                .accessibilityHint("识别文本中的地点并自动插入地点标签")
                .buttonStyle(.plain)

                Button {
                    showImportSheet = true
                } label: {
                    toolbarIcon("square.and.arrow.down")
                }
                .disabled(isLocked)
                .accessibilityLabel("导入地点")
                .buttonStyle(.plain)

                Button {
                    isLocked.toggle()
                } label: {
                    toolbarIcon(isLocked ? "lock.fill" : "lock.open")
                }
                .accessibilityLabel(isLocked ? "解锁编辑" : "锁定编辑")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func modeButton(_ item: ViewMode, systemImage: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                mode = item
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.medium))
                Text(item.title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(mode == item ? AppTheme.foreground : AppTheme.foregroundSoft)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(mode == item ? AppTheme.paper : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
    }

    private func oneClickConvert() async {
        guard let note else { return }
        isConverting = true
        defer { isConverting = false }

        let text = MarkdownService.stripPlaceTags(note.markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let result = try await GeminiService.shared.extractPlaces(from: text)
            let filtered = AIParsingService.filterBroadNames(result.places)
            var md = note.markdown
            var collectedPlaces = note.places
            var locationBias = note.places.averageLatLng

            for aiPlace in filtered {
                let mapPlace = await findPlaceWithFallback(place: aiPlace, locationBias: locationBias, city: result.region)
                guard let mapPlace else { continue }
                if locationBias == nil { locationBias = LatLng(lat: mapPlace.lat, lng: mapPlace.lng) }

                if collectedPlaces.contains(where: { $0.name == aiPlace.name }) { continue }
                let chosenName = mapPlace.name.isCJK || !aiPlace.name.isCJK ? mapPlace.name : aiPlace.name
                let place = Place(
                    name: chosenName,
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

                if md.contains(aiPlace.name) {
                    md = MarkdownService.replaceFirstOccurrence(in: md, target: aiPlace.name, replacement: "::place[\(chosenName)]{#\(place.id)}")
                    collectedPlaces.append(place)
                }
            }

            store.updateNote(noteID) { note in
                note.markdown = md
                note.places = collectedPlaces
            }
            noticeText = collectedPlaces.count == note.places.count ? "未识别到新的地点标签" : "已完成地点智能转换"
        } catch {
            noticeText = "未配置 Gemini Key，无法执行智能转换"
        }
    }

    private func findPlaceWithFallback(place: AIExtractPlace, locationBias: LatLng?, city: String?) async -> MapPlace? {
        let options = SearchOptions(locationBias: locationBias, radius: 50000, city: city)
        let primary = await store.currentEngine.findPlace(query: place.searchQuery, options: options)
        if primary != nil { return primary }
        for alias in place.aliases ?? [] {
            if let hit = await store.currentEngine.findPlace(query: alias, options: options) {
                return hit
            }
        }
        return await store.currentEngine.findPlace(query: place.searchQuery, options: SearchOptions(locationBias: nil, radius: 50000, city: city))
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(AppTheme.foreground)
            .frame(width: 44, height: 44)
    }

    private func statusBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.primary)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 6, y: 2)
    }
}

