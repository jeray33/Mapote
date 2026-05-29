import SwiftUI
import CoreLocation

struct NoteListScreen: View {
    @EnvironmentObject private var store: NoteStore
    @State private var showSettings = false
    @State private var resolvedRegionsByGeoKey: [String: String] = [:]
    @State private var resolvingRegionKeys: Set<String> = []

    private var allPlaces: [Place] {
        var merged: [Place] = []
        for note in store.notes {
            merged.append(contentsOf: placesForHeader(note: note))
        }
        return merged
    }
    private var collectedPlaces: [Place] {
        var seen: Set<String> = []
        var merged: [Place] = []
        for place in allPlaces {
            let key = placeDedupKey(place)
            guard seen.insert(key).inserted else { continue }
            merged.append(place)
        }
        return merged
    }

    private var globePlaces: [Place] {
        collectedPlaces
    }

    private var statsRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 22) {
            statCell(title: "国家/地区", value: regionCount)
            statCell(title: "地点", value: allPlaces.count)
            statCell(title: "笔记", value: store.notes.count)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statCell(title: String, value: Int) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.foreground)
            Text("\(value)")
                .font(.system(size: 34, weight: .light, design: .rounded))
                .foregroundStyle(AppTheme.foreground)
        }
    }

    private var globeMarkers: [CobeMarker] {
        globePlaces.map { place in
            CobeMarker(
                id: place.id,
                lat: place.lat,
                lng: place.lng,
                country: resolvedRegionName(for: place),
                image: preferredImageURLString(for: place),
                caption: place.name,
                rotate: polaroidRotation(for: place)
            )
        }
    }

    private var regionCount: Int {
        let names = allPlaces.map(resolvedRegionName(for:))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "unknown" }
        return Set(names).count
    }

    private var regionResolveTaskKey: Int {
        var hasher = Hasher()
        for place in allPlaces {
            hasher.combine(geoKey(for: place))
        }
        return hasher.finalize()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if store.notes.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            globeHero
                            emptyState
                        }
                        .padding(.horizontal, 16)
                    }
                } else {
                    List {
                        globeHero
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 32, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        ForEach(store.notes) { note in
                            NoteCard(
                                note: note,
                                onSelect: {
                                    store.select(noteID: note.id)
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 22, leading: 37, bottom: 22, trailing: 50))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(noteID: note.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.foregroundSoft)
                                .frame(width: 32, height: 32)
                                .background(AppTheme.paper.opacity(0.9))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("应用配置")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            store.createNoteAndOpen()
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(AppTheme.primary)
                                .clipShape(Circle())
                                .shadow(color: AppTheme.primary.opacity(0.4), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("新建笔记")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
        }
        .task(id: regionResolveTaskKey) {
            await resolveRegionsIfNeeded()
        }
    }

    private var globeHero: some View {
        VStack(spacing: 14) {
            CobeGlobeView(markers: globeMarkers)
                .aspectRatio(0.9, contentMode: .fit)
                .frame(maxWidth: 292)
                .frame(maxWidth: .infinity)

            statsRow
        }
        .padding(.bottom, 6)
    }

    private func placesForHeader(note: Note) -> [Place] {
        let ordered = MarkdownService.orderedPlaces(note: note)
        return ordered.isEmpty ? note.places : ordered
    }

    private func placeDedupKey(_ place: Place) -> String {
        if let placeId = place.placeId, !placeId.isEmpty {
            return "pid:\(placeId.lowercased())"
        }
        let lat = Int((place.lat * 10_000).rounded())
        let lng = Int((place.lng * 10_000).rounded())
        return "geo:\(lat):\(lng):\(place.name.lowercased())"
    }

    private func preferredImageURLString(for place: Place) -> String? {
        let candidates = [place.image].compactMap { $0 } + (place.images ?? [])
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), (url.scheme == "https" || url.scheme == "http") {
                return normalizedPlaceImageURL(url).absoluteString
            }
            let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
            if let url = URL(string: escaped), (url.scheme == "https" || url.scheme == "http") {
                return normalizedPlaceImageURL(url).absoluteString
            }
        }
        return nil
    }

    private func polaroidRotation(for place: Place) -> Double {
        let seed = place.id.unicodeScalars.reduce(0) { partial, scalar in
            partial + Int(scalar.value)
        }
        return Double((seed % 13) - 6)
    }
    private func geoKey(for place: Place) -> String {
        let lat = Int((place.lat * 1000).rounded())
        let lng = Int((place.lng * 1000).rounded())
        return "geo:\(lat):\(lng)"
    }

    private func resolvedRegionName(for place: Place) -> String {
        let key = geoKey(for: place)
        if let resolved = resolvedRegionsByGeoKey[key], !resolved.isEmpty {
            return resolved
        }
        return fallbackRegionName(for: place)
    }

    @MainActor
    private func resolveRegionsIfNeeded() async {
        for place in allPlaces {
            let key = geoKey(for: place)
            if resolvedRegionsByGeoKey[key] != nil || resolvingRegionKeys.contains(key) {
                continue
            }
            resolvingRegionKeys.insert(key)
            if let resolved = await reverseGeocodeRegionName(lat: place.lat, lng: place.lng) {
                resolvedRegionsByGeoKey[key] = resolved
            } else {
                resolvedRegionsByGeoKey[key] = fallbackRegionName(for: place)
            }
            resolvingRegionKeys.remove(key)
        }
    }

    private func reverseGeocodeRegionName(lat: Double, lng: Double) async -> String? {
        let location = CLLocation(latitude: lat, longitude: lng)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let first = placemarks.first else { return nil }
            let candidate = first.country ?? first.administrativeArea ?? first.locality ?? first.isoCountryCode
            return candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func fallbackRegionName(for place: Place) -> String {
        let trimmed = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        if trimmed.contains("中国") || trimmed.contains("中华人民共和国") {
            return "中国"
        }
        if trimmed.contains("香港") {
            return "中国香港"
        }
        if trimmed.contains("澳门") {
            return "中国澳门"
        }
        if trimmed.contains("台湾") || trimmed.contains("台灣") {
            return "中国台湾"
        }

        let commaParts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let tail = commaParts.last {
            return tail
        }

        let tokens = trimmed
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let tail = tokens.last {
            return tail
        }

        return trimmed
    }


    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AppTheme.secondary)
                    .frame(width: 88, height: 88)
                Image(systemName: "map.fill")
                    .font(.largeTitle)
                    .foregroundStyle(AppTheme.primary)
            }

            VStack(spacing: 6) {
                Text("还没有旅行笔记")
                    .font(.title2.weight(.bold))
                Text("从一段文字开始，逐步整理地点、路线和地图。")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.foregroundSoft)
                    .multilineTextAlignment(.center)
            }

            Button("创建第一份笔记") {
                store.createNoteAndOpen()
            }
            .buttonStyle(.mapotePrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 12, y: 4)
    }
}

private struct NoteCard: View {
    let note: Note
    let onSelect: () -> Void

    var orderedPlaces: [Place] { MarkdownService.orderedPlaces(note: note) }
    var previewPlaces: [Place] { Array(orderedPlaces.prefix(3)) }
    private var visibleTagNames: [String] { Array(orderedPlaces.prefix(6).map(\.name)) }
    private var firstTagRow: [String] { Array(visibleTagNames.prefix(3)) }
    private var secondTagRow: [String] { Array(visibleTagNames.dropFirst(3).prefix(3)) }

    var body: some View {
        HStack(spacing: 48) {
            imageStack
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(note.title.isEmpty ? "未命名笔记" : note.title)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Color.black)
                        .lineLimit(1)
                    Spacer()
                }
                flowTags
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private var imageStack: some View {
        ZStack(alignment: .bottom) {
            if previewPlaces.indices.contains(1) {
                coverLayer(for: previewPlaces[1], angle: 8)
                    .frame(width: 48, height: 64, alignment: .center)
                    .offset(x: 24, y: 0)
                    .zIndex(1)
            }

            if previewPlaces.indices.contains(2) {
                coverLayer(for: previewPlaces[2], angle: -8)
                    .frame(width: 48, height: 64, alignment: .center)
                    .offset(x: 0, y: 0)
                    .zIndex(2)
            }

            coverLayer(for: previewPlaces.first, angle: 0)
                .frame(width: 48, height: 64, alignment: .center)
                .offset(x: 12, y: 12)
                .zIndex(3)
        }
    }

    @ViewBuilder
    private func coverLayer(for place: Place?, angle: Double) -> some View {
        Group {
            if let place {
                if let url = preferredImageURL(for: place) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AppTheme.muted).overlay { ProgressView().scaleEffect(0.7) }
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AppTheme.muted).overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        @unknown default:
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AppTheme.muted)
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.muted)
                        .overlay {
                            Image(systemName: (place.category ?? .other).sfSymbol)
                                .foregroundStyle((place.category ?? .other).color)
                        }
                }
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AppTheme.muted)
            }
        }
        .frame(width: 48, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Color.white.opacity(0.98), lineWidth: 1.5)
        )
        .rotationEffect(.degrees(angle))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 4)
    }

    private func preferredImageURL(for place: Place) -> URL? {
        let candidates = [place.image].compactMap { $0 } + (place.images ?? [])
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), (url.scheme == "https" || url.scheme == "http") {
                return normalizedPlaceImageURL(url)
            }
            let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
            if let url = URL(string: escaped), (url.scheme == "https" || url.scheme == "http") {
                return normalizedPlaceImageURL(url)
            }
        }
        return nil
    }

    private var flowTags: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(firstTagRow, id: \.self) { name in
                    tagChip(name)
                }
            }
            HStack(spacing: 6) {
                ForEach(secondTagRow, id: \.self) { name in
                    tagChip(name)
                }
                countChip
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
            )
    }

    private var countChip: some View {
        Text("\(orderedPlaces.count)")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.8))
            .clipShape(Capsule())
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return "更新于 \(formatter.string(from: Date(timeIntervalSince1970: note.updatedAt / 1000)))"
    }
}

private func normalizedPlaceImageURL(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "http"
    else { return url }
    components.scheme = "https"
    return components.url ?? url
}
