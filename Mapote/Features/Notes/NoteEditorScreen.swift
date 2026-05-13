import SwiftUI
import UIKit

struct NoteEditorScreen: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String

    @State private var mode: ViewMode = .note
    @State private var isLocked = false
    @State private var showImportSheet = false
    @State private var showAIChat = false
    @State private var isConverting = false
    @State private var noticeText: String?
    @State private var isKeyboardVisible = false
    @State private var sheetDetent: PresentationDetent = .large
    @State private var didSetInitialDetent = false
    @State private var listSectionIndex = 0
    @State private var mapFocusTrigger = 0
    @AppStorage(AppConfigKey.aiChatEnabled) private var aiChatEnabled = true

    private static let collapsedDetentHeight: CGFloat = 64

    private var note: Note? {
        store.notes.first(where: { $0.id == noteID })
    }

    private var listSections: [MarkdownService.Section] {
        guard let note else { return [] }
        return MarkdownService.getPlacesBySection(note: note)
    }

    private var mapVisiblePlaceIDs: Set<String>? {
        guard mode == .list else { return nil }
        guard !listSections.isEmpty else { return nil }
        guard listSectionIndex > 0, listSections.indices.contains(listSectionIndex - 1) else { return nil }
        return Set(listSections[listSectionIndex - 1].placeIDs)
    }

    var body: some View {
        if let note {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    MapBackgroundView(
                        noteID: noteID,
                        visiblePlaceIDs: mapVisiblePlaceIDs,
                        focusTrigger: mapFocusTrigger
                    )
                        .environmentObject(store)

                    topMapBlurOverlay

                    floatingBackButton
                        .padding(.leading, 12)
                        .padding(.top, 8)

                    floatingFocusButton(screenHeight: proxy.size.height, safeBottom: proxy.safeAreaInsets.bottom)
                }
                .background(AppTheme.background.ignoresSafeArea())
            }
            .sheet(isPresented: .constant(true)) {
                sheetBody(note: note)
                    .presentationDetents(
                        [.height(Self.collapsedDetentHeight), .medium, .large],
                        selection: $sheetDetent
                    )
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                    .interactiveDismissDisabled(true)
            }
            .onAppear {
                guard !didSetInitialDetent else { return }
                sheetDetent = note.places.isEmpty ? .large : .medium
                didSetInitialDetent = true
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .note {
                    listSectionIndex = 0
                }
            }
            .onChange(of: listSections.count) { _, _ in
                if listSections.isEmpty {
                    listSectionIndex = 0
                } else if listSectionIndex > listSections.count {
                    listSectionIndex = 0
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
        }
    }

    private var topMapBlurOverlay: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 180)
            .mask(
                LinearGradient(
                    colors: [.white, .white.opacity(0.7), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func sheetBody(note: Note) -> some View {
        VStack(spacing: 0) {
            if mode == .note {
                titleBar(note: note)
                if let noticeText {
                    statusBanner(text: noticeText)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                ZStack(alignment: .bottomTrailing) {
                    EditModeView(
                        noteID: noteID,
                        isLocked: $isLocked
                    )
                    .environmentObject(store)

                    if aiChatEnabled, !isKeyboardVisible {
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
                        .padding(.bottom, 16)
                        .accessibilityLabel("AI 聊天")
                    }
                }
            } else {
                ListModeView(
                    noteID: noteID,
                    sectionIndex: $listSectionIndex,
                    onToggleMode: { toggleMode() }
                )
                    .environmentObject(store)
            }
        }
        .background(AppTheme.background)
        .sheet(isPresented: $showImportSheet) {
            ImportPlacesSheet(noteID: noteID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAIChat) {
            AIChatSheet(noteID: noteID)
                .environmentObject(store)
                .presentationDetents([.fraction(0.7)])
        }
    }

    private var floatingBackButton: some View {
        Button {
            store.select(noteID: nil)
        } label: {
            Image(systemName: "arrow.left")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 42, height: 42)
                .background(AppTheme.paper)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                .shadow(color: AppTheme.shadow, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回笔记列表")
    }

    private func titleBar(note: Note) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("笔记标题", text: Binding(
                get: { note.title },
                set: { store.updateTitle(noteID: noteID, title: $0) }
            ))
            .font(.title2.weight(.bold))
            .textFieldStyle(.plain)
            .foregroundStyle(AppTheme.foreground)
            .disabled(isLocked)

            noteMoreMenu
            modeToggleButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(UIColor.separator).opacity(0.6))
                .frame(height: 0.5)
        }
    }

    private var noteMoreMenu: some View {
        Menu {
            Button {
                Task { await oneClickConvert() }
            } label: {
                Label(isConverting ? "智能识别中..." : "AI 识别地点", systemImage: "sparkles")
            }
            .disabled(isConverting || isLocked)

            Button {
                showImportSheet = true
            } label: {
                Label("批量导入地点", systemImage: "square.and.arrow.down")
            }
            .disabled(isLocked)

            Button {
                isLocked.toggle()
            } label: {
                Label(isLocked ? "解锁编辑" : "锁定编辑", systemImage: isLocked ? "lock.open" : "lock.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 36, height: 36)
                .background(AppTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
        .accessibilityLabel("更多操作")
    }

    private var modeToggleButton: some View {
        Button(action: toggleMode) {
            toolbarIcon(mode == .note ? "list.bullet" : "pencil")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .note ? "切换到列表模式" : "切换到笔记模式")
    }

    private func toggleMode() {
        withAnimation(.easeOut(duration: 0.18)) {
            mode = mode == .note ? .list : .note
        }
    }

    private func floatingFocusButton(screenHeight: CGFloat, safeBottom: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    mapFocusTrigger += 1
                } label: {
                    Image(systemName: "scope")
                        .font(.headline)
                        .foregroundStyle(AppTheme.foreground)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.paper)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到地点中心")
                .padding(.trailing, 14)
                .padding(.bottom, focusButtonBottomPadding(screenHeight: screenHeight, safeBottom: safeBottom))
            }
        }
    }

    private func focusButtonBottomPadding(screenHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        let sheetHeight = estimatedSheetHeight(screenHeight: screenHeight, safeBottom: safeBottom)
        let target = sheetHeight + 14
        return min(target, max(72, screenHeight - 96))
    }

    private func estimatedSheetHeight(screenHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        if sheetDetent == .large {
            return max(screenHeight * 0.86, 340)
        }
        if sheetDetent == .medium {
            return max(screenHeight * 0.5, 260)
        }
        return Self.collapsedDetentHeight + safeBottom
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
                note.blocks = nil
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
