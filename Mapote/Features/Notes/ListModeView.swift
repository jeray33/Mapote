import SwiftUI

struct ListModeView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String

    @State private var expandedIDs: Set<String> = []
    @State private var sectionIndex = 0
    @State private var loadingRoutes: Set<String> = []

    private var note: Note? { store.notes.first(where: { $0.id == noteID }) }

    private var sections: [MarkdownService.Section] {
        guard let markdown = note?.markdown else { return [] }
        return MarkdownService.getPlacesBySection(markdown: markdown)
    }

    private var allOrderedPlaces: [Place] {
        guard let note else { return [] }
        return note.places
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
                ForEach(currentPlaces) { place in
                    placeCard(place)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if let idx = currentPlaces.firstIndex(where: { $0.id == place.id }), idx < currentPlaces.count - 1 {
                        routeRow(from: place, to: currentPlaces[idx + 1])
                            .padding(.horizontal, 12)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                summaryFooter
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 24, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .task(id: note?.id) {
            await requestSuggestedDurations()
        }
    }

    private var shouldShowTopTabs: Bool {
        !sections.isEmpty || currentPlaces.count >= 3
    }

    private var topTabs: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tab(title: "全部", index: 0)
                    ForEach(Array(sections.enumerated()), id: \.offset) { idx, sec in
                        tab(title: sec.title, index: idx + 1)
                    }
                }
            }
            if currentPlaces.count >= 3 {
                Button {
                    smartSortCurrentSection()
                } label: {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.paper.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("智能排序地点")
                .accessibilityHint("按更顺路的顺序排序当前分段地点")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(AppTheme.paper)
    }

    private func tab(title: String, index: Int) -> some View {
        Button(title) { sectionIndex = index }
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .foregroundStyle(sectionIndex == index ? AppTheme.foreground : AppTheme.foregroundSoft)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(sectionIndex == index ? AppTheme.primary : .clear)
                    .frame(height: 2)
            }
    }

    private func placeCard(_ place: Place) -> some View {
        let expanded = expandedIDs.contains(place.id)
        let notes = note.map { MarkdownService.extractPlaceNotes(markdown: $0.markdown) } ?? [:]
        let contextNote = notes[place.id] ?? ""
        let merged = mergedNote(contextNote: contextNote, manualNote: place.note)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                placeThumbnail(place)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((place.category ?? .other).emoji)
                            .font(.caption2)
                        Text(place.name)
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
        .padding(16)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 8, y: 3)
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
                return url
            }
            let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
            if let url = URL(string: escaped), (url.scheme == "https" || url.scheme == "http") {
                return url
            }
        }
        return nil
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

    private func requestSuggestedDurations() async {
        guard let note else { return }
        let missing = note.places.filter { $0.suggestedDuration == nil }
        guard !missing.isEmpty else { return }
        do {
            let result = try await GeminiService.shared.suggestDurations(placeNames: missing.map(\.name))
            store.updateNote(noteID) { note in
                note.places = note.places.map { place in
                    var p = place
                    if p.suggestedDuration == nil {
                        p.suggestedDuration = result[p.name]
                    }
                    return p
                }
            }
        } catch {
            // 无 API Key 时忽略
        }
    }
}

