import SwiftUI

struct ListModeView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String
    @Binding var sectionIndex: Int
    let onToggleMode: () -> Void

    @State private var expandedIDs: Set<String> = []
    @State private var loadingRoutes: Set<String> = []

    private var note: Note? { store.notes.first(where: { $0.id == noteID }) }

    private var sections: [MarkdownService.Section] {
        guard let note else { return [] }
        return MarkdownService.getPlacesBySection(note: note)
    }

    private var allOrderedPlaces: [Place] {
        guard let note else { return [] }
        let ordered = MarkdownService.orderedPlaces(note: note)
        return shouldFallbackToMetadataPlaces(note: note, ordered: ordered) ? note.places : ordered
    }

    private func shouldFallbackToMetadataPlaces(note: Note, ordered: [Place]) -> Bool {
        // Tiptap JSON is the source of truth for which places are in the note.
        // If blocks exist and contain zero placeRefs, the list must be empty;
        // falling back to metadata would resurrect deleted tags/places.
        !BlocksFeatureFlag.useBlocksAsSource || note.blocks == nil ? ordered.isEmpty : false
    }

    private var currentPlaces: [Place] {
        guard !sections.isEmpty, sectionIndex > 0, sections.indices.contains(sectionIndex - 1) else {
            return allOrderedPlaces
        }
        let sec = sections[sectionIndex - 1]
        let idSet = Set(sec.placeIDs)
        return allOrderedPlaces.filter { idSet.contains($0.id) || idSet.contains($0.placeId ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowTopTabs {
                topTabs
            }
            List {
                ForEach(Array(currentPlaces.enumerated()), id: \.element.id) { idx, place in
                    VStack(spacing: 0) {
                        placeCard(place, index: idx)
                        if idx < currentPlaces.count - 1 {
                            routeRow(from: place, to: currentPlaces[idx + 1])
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .background(ReorderHandleHider())
                }
                .onMove { from, to in
                    var places = currentPlaces
                    places.move(fromOffsets: from, toOffset: to)
                    store.reorderPlaces(noteID: noteID, newOrder: places)
                    store.reorderPlacesInBlocks(
                        noteID: noteID,
                        newIDOrder: places.map(\.id),
                        scopeTitle: currentSectionTitle
                    )
                }
                summaryFooter
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 24, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .onAppear {
            normalizeSectionIndex()
        }
        .onChange(of: sections.count) { _, _ in
            normalizeSectionIndex()
        }
    }

    private var currentSectionTitle: String? {
        guard sectionIndex > 0, sections.indices.contains(sectionIndex - 1) else { return nil }
        return sections[sectionIndex - 1].title
    }

    private var shouldShowTopTabs: Bool {
        true
    }

    private var topTabs: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !sections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        tab(title: "全部", index: 0)
                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, sec in
                            tab(title: sec.title, index: idx + 1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onToggleMode) {
                Image(systemName: "pencil.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.paper.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换到笔记模式")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 0)
        .background(AppTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(UIColor.separator).opacity(0.6))
                .frame(height: 0.5)
        }
    }

    private func normalizeSectionIndex() {
        if sections.isEmpty || sectionIndex > sections.count {
            sectionIndex = 0
        }
    }

    private func tab(title: String, index: Int) -> some View {
        Button { sectionIndex = index } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(sectionIndex == index ? AppTheme.foreground : AppTheme.foregroundSoft)
                Rectangle()
                    .fill(sectionIndex == index ? Color(red: 68 / 255, green: 215 / 255, blue: 1.0) : .clear)
                    .frame(height: 2)
                    .offset(y: 1)
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 0)
        }
        .buttonStyle(.plain)
    }

    private func placeCard(_ place: Place, index: Int) -> some View {
        let expanded = expandedIDs.contains(place.id)
        let notes = note.map { MarkdownService.extractPlaceNotes(markdown: $0.markdown) } ?? [:]
        let contextNote = notes[place.id] ?? ""
        let merged = mergedNote(contextNote: contextNote, manualNote: place.note)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                placeThumbnail(place)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1). \(place.name)")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.foreground)
                        Spacer()
                        Button {
                            toggleExpanded(place.id)
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(AppTheme.foregroundSoft)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? "收起地点详情" : "展开地点详情")
                    }
                    HStack(spacing: 8) {
                        if let firstHour = place.openingHours?.first {
                            Label(firstHour, systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(AppTheme.foregroundSoft)
                                .lineLimit(1)
                        }
                        if let suggest = place.suggestedDuration {
                            Text("建议\(suggest)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.primary)
                        }
                    }
                    if !merged.preview.isEmpty {
                        Text(merged.preview).font(.caption).foregroundStyle(AppTheme.foregroundSoft).lineLimit(2)
                    }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.address).font(.caption).foregroundStyle(AppTheme.foreground)
                    if let desc = place.description {
                        Text(desc).font(.caption).foregroundStyle(AppTheme.foregroundSoft)
                    }
                    if let hours = place.openingHours {
                        ForEach(hours, id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(AppTheme.foregroundSoft)
                        }
                    }
                    if !merged.context.isEmpty || !merged.manual.isEmpty {
                        Divider()
                    }
                    if !merged.context.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上下文备注").font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.foregroundSoft)
                            Text(merged.context).font(.caption).foregroundStyle(AppTheme.foregroundSoft)
                        }
                    }
                    if !merged.manual.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("手动备注").font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.foregroundSoft)
                            Text(merged.manual).font(.caption).foregroundStyle(AppTheme.foregroundSoft)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func mergedNote(contextNote: String, manualNote: String) -> (preview: String, context: String, manual: String) {
        let context = contextNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = manualNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if !manual.isEmpty {
            preview = manual
        } else {
            preview = context
        }
        return (preview, context, manual)
    }

    private func routeRow(from: Place, to: Place) -> some View {
        let key = RouteUtils.key(from, to)
        let route = note?.routeInfos[key]
        return HStack {
            if let route {
                Button {
                    Task { await cycleMode(for: from, to: to, fromInfo: route) }
                } label: {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(AppTheme.primary.opacity(0.25))
                            .frame(width: 2, height: 18)
                        Label("\(route.distance)  \(route.duration)", systemImage: route.travelMode.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                }
                .buttonStyle(.plain)
            } else if loadingRoutes.contains(key) {
                ProgressView().scaleEffect(0.8)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func placeThumbnail(_ place: Place) -> some View {
        if let url = preferredImageURL(for: place) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.muted)
                        .overlay { ProgressView().scaleEffect(0.75) }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.muted)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(AppTheme.foregroundSoft)
                        }
                @unknown default:
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.muted)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.muted)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: (place.category ?? .other).sfSymbol)
                        .font(.title3)
                        .foregroundStyle((place.category ?? .other).color)
                }
        }
    }

    private func preferredImageURL(for place: Place) -> URL? {
        let candidates = [place.image].compactMap { $0 } + (place.images ?? [])
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), (url.scheme == "https" || url.scheme == "http") {
                return normalizedImageURL(url)
            }
            let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
            if let url = URL(string: escaped), (url.scheme == "https" || url.scheme == "http") {
                return normalizedImageURL(url)
            }
        }
        return nil
    }

    private func normalizedImageURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http"
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    private var summaryFooter: some View {
        let summary = RouteUtils.summarize(routeInfos: currentRouteInfos)
        return HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(AppTheme.primary)
            Text("总路程 \(summary.distance) · 总耗时 \(summary.duration)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.foregroundSoft)
            Spacer()
        }
        .padding(16)
        .background(AppTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var currentRouteInfos: [String: RouteInfo] {
        guard let routeInfos = note?.routeInfos, currentPlaces.count >= 2 else { return [:] }
        let keys = (0..<(currentPlaces.count - 1)).map { idx in
            RouteUtils.key(currentPlaces[idx], currentPlaces[idx + 1])
        }
        return routeInfos.filter { keys.contains($0.key) }
    }

    private func toggleExpanded(_ placeID: String) {
        if expandedIDs.contains(placeID) {
            expandedIDs.remove(placeID)
        } else {
            expandedIDs.insert(placeID)
        }
        Task { await lazyLoadRoutes() }
    }

    private func lazyLoadRoutes() async {
        guard let note else { return }
        let places = currentPlaces
        guard places.count >= 2 else { return }
        for idx in 0..<(places.count - 1) {
            let from = places[idx]
            let to = places[idx + 1]
            let key = RouteUtils.key(from, to)
            if note.routeInfos[key] != nil { continue }
            if !expandedIDs.contains(from.id) && !expandedIDs.contains(to.id) { continue }

            loadingRoutes.insert(key)
            defer { loadingRoutes.remove(key) }

            let modes: [TravelMode] = [.DRIVING, .WALKING, .TRANSIT]
            var candidates: [(TravelMode, MapDirectionsResult)] = []
            for mode in modes {
                if let result = await store.currentEngine.getDirections(from: LatLng(lat: from.lat, lng: from.lng), to: LatLng(lat: to.lat, lng: to.lng), mode: mode) {
                    candidates.append((mode, result))
                }
            }
            if let fastest = candidates.min(by: { $0.1.durationSeconds < $1.1.durationSeconds }) {
                store.setRouteInfo(
                    noteID: noteID,
                    key: key,
                    info: RouteInfo(distance: fastest.1.distanceText, duration: fastest.1.durationText, travelMode: fastest.0)
                )
            }
        }
    }

    private func cycleMode(for from: Place, to: Place, fromInfo: RouteInfo) async {
        let nextMode = fromInfo.travelMode.next()
        if let result = await store.currentEngine.getDirections(from: LatLng(lat: from.lat, lng: from.lng), to: LatLng(lat: to.lat, lng: to.lng), mode: nextMode) {
            store.setRouteInfo(
                noteID: noteID,
                key: RouteUtils.key(from, to),
                info: RouteInfo(distance: result.distanceText, duration: result.durationText, travelMode: nextMode)
            )
        }
    }

    private func smartSortCurrentSection() {
        guard let note else { return }
        let sortedCurrent = RouteUtils.nearestNeighborSort(currentPlaces)
        let selectedSet = Set(currentPlaces.map(\.id))
        let untouched = note.places.filter { !selectedSet.contains($0.id) }
        let merged = sortedCurrent + untouched
        store.reorderPlaces(noteID: noteID, newOrder: merged)
    }

}

// MARK: - Hide native reorder handle icon

private struct ReorderHandleHider: UIViewRepresentable {
    func makeUIView(context: Context) -> _Hider { _Hider() }
    func updateUIView(_ uiView: _Hider, context: Context) { uiView.hideHandle() }

    class _Hider: UIView {
        func hideHandle() {
            DispatchQueue.main.async { [weak self] in
                self?.nearestCell()?.subviews.first {
                    String(describing: type(of: $0)) == "UITableViewCellReorderControl"
                }?.isHidden = true
            }
        }

        private func nearestCell() -> UITableViewCell? {
            sequence(first: self as UIView, next: \.superview)
                .compactMap { $0 as? UITableViewCell }
                .first
        }
    }
}
