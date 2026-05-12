import SwiftUI
import MapKit

struct MapModeView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String

    @State private var position: MapCameraPosition = .automatic
    @State private var selectedPlace: Place?
    @State private var sectionIndex = 0
    @State private var routePolylines: [String: [LatLng]] = [:]
    @State private var routePolylineCache: [String: [LatLng]] = [:]

    private var note: Note? { store.notes.first(where: { $0.id == noteID }) }
    private var sections: [MarkdownService.Section] {
        guard let markdown = note?.markdown else { return [] }
        return MarkdownService.getPlacesBySection(markdown: markdown)
    }

    private var orderedPlaces: [Place] {
        guard let note else { return [] }
        let all = MarkdownService.orderedPlaces(note: note)
        guard sectionIndex > 0, sections.indices.contains(sectionIndex - 1) else { return all }
        let set = Set(sections[sectionIndex - 1].placeIDs)
        return all.filter { set.contains($0.id) || set.contains($0.placeId ?? "") }
    }

    private var routeTaskKey: String {
        let ids = orderedPlaces.map(\.id).joined(separator: "|")
        return "\(store.mapSettings.showRoute)|\(ids)"
    }

    private var mapKitStyle: MapStyle {
        switch store.mapSettings.theme {
        case "dark", "night":
            return .imagery(elevation: .realistic)
        default:
            return .standard(elevation: .flat)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            VStack(spacing: 8) {
                if let mapEngineError = store.mapEngineError {
                    Text(mapEngineError)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.yellow.opacity(0.18))
                        .clipShape(Capsule())
                }
                topControls
                    .padding(.horizontal, -12)
                    .padding(.top, -12)
                Spacer()
                if let selectedPlace {
                    mapPlaceCard(selectedPlace)
                        .padding(.bottom, 4)
                }
            }
            .padding(12)

            Button {
                focusCurrentTabPlaces()
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
            .padding(.trailing, 14)
            .padding(.bottom, selectedPlace == nil ? 16 : 196)
        }
        .onAppear { fitBounds() }
        .onChange(of: orderedPlaces) { _, _ in fitBounds() }
        .task(id: routeTaskKey) {
            await loadRoutePolylines()
        }
    }

    private var mapLayer: some View {
        Map(position: $position, selection: $selectedPlace) {
            ForEach(orderedPlaces) { place in
                if store.mapSettings.poiToggles[place.category ?? .other] ?? true {
                    Marker(
                        store.mapSettings.showName ? place.name : "",
                        systemImage: store.mapSettings.showNumber ? "\(max(1, orderedPlaces.firstIndex(where: { $0.id == place.id })! + 1)).circle.fill" : "mappin",
                        coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
                    )
                    .tint((place.category ?? .other).color)
                    .tag(place)
                }
            }
            if store.mapSettings.showConnections {
                ForEach(Array(orderedPlaces.indices.dropLast()), id: \.self) { idx in
                    MapPolyline(coordinates: [
                        CLLocationCoordinate2D(latitude: orderedPlaces[idx].lat, longitude: orderedPlaces[idx].lng),
                        CLLocationCoordinate2D(latitude: orderedPlaces[idx + 1].lat, longitude: orderedPlaces[idx + 1].lng)
                    ])
                    .stroke(AppTheme.primary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [5]))
                }
            }
            if store.mapSettings.showRoute {
                ForEach(Array(orderedPlaces.indices.dropLast()), id: \.self) { idx in
                    let from = orderedPlaces[idx]
                    let to = orderedPlaces[idx + 1]
                    let key = RouteUtils.key(from, to)
                    let coords = (routePolylines[key]?.map(\.cl)).flatMap { $0.isEmpty ? nil : $0 } ?? [
                        CLLocationCoordinate2D(latitude: from.lat, longitude: from.lng),
                        CLLocationCoordinate2D(latitude: to.lat, longitude: to.lng)
                    ]
                    MapPolyline(coordinates: coords)
                        .stroke(AppTheme.primary.opacity(0.75), lineWidth: 4)
                }
            }
        }
        .mapStyle(mapKitStyle)
    }

    private var topControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tab("全部", idx: 0)
                ForEach(Array(sections.enumerated()), id: \.offset) { i, sec in
                    tab(sec.title, idx: i + 1)
                }
            }
        }
        .padding(.vertical, 2)
        .background(AppTheme.paper)
    }

    private func tab(_ title: String, idx: Int) -> some View {
        Button(title) { sectionIndex = idx }
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .foregroundStyle(sectionIndex == idx ? AppTheme.foreground : AppTheme.foregroundSoft)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(sectionIndex == idx ? AppTheme.primary : .clear)
                    .frame(height: 2)
            }
    }

    private func mapPlaceCard(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaceImageCarouselView(
                imageURLs: place.images ?? (place.image.map { [$0] } ?? []),
                height: 150
            )
            HStack {
                Circle()
                    .fill((place.category ?? .other).color)
                    .frame(width: 24, height: 24)
                    .overlay { Text("\((orderedPlaces.firstIndex(where: { $0.id == place.id }) ?? 0) + 1)").font(.caption2).foregroundStyle(.white) }
                Text(place.name).font(.headline)
                Spacer()
                Text((place.category ?? .other).title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((place.category ?? .other).iconBackground)
                    .foregroundStyle((place.category ?? .other).color)
                    .clipShape(Capsule())
            }
            Text(place.address).font(.caption).foregroundStyle(.secondary)
            if let desc = place.description {
                Text(desc).font(.caption).lineLimit(2)
            } else {
                Text("暂无更多图文信息，可在编辑模式补充地点备注。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.foregroundSoft)
            }
            HStack(spacing: 12) {
                if let rating = place.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let suggest = place.suggestedDuration {
                    Text("建议 \(suggest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let today = place.openingHours?.first {
                Text(today)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("导航") {
                    if let url = URL(string: "http://maps.apple.com/?daddr=\(place.lat),\(place.lng)") {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.mapotePrimary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(AppTheme.paper.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 8, y: 3)
        .frame(maxWidth: 430)
    }

    private func fitBounds() {
        guard !orderedPlaces.isEmpty else { return }
        if orderedPlaces.count == 1, let first = orderedPlaces.first {
            position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng), latitudinalMeters: 1500, longitudinalMeters: 1500))
            return
        }
        let lats = orderedPlaces.map(\.lat)
        let lngs = orderedPlaces.map(\.lng)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let latDelta = max((maxLat - minLat) * 1.6, 0.02)
        let lngDelta = max((maxLng - minLng) * 1.6, 0.02)
        position = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)))
    }

    private func focusCurrentTabPlaces() {
        fitBounds()
    }

    private func loadRoutePolylines() async {
        guard store.mapSettings.showRoute, orderedPlaces.count >= 2 else {
            routePolylines = [:]
            return
        }

        let pairs: [(key: String, from: Place, to: Place)] = (0..<(orderedPlaces.count - 1)).map { idx in
            let from = orderedPlaces[idx]
            let to = orderedPlaces[idx + 1]
            return (RouteUtils.key(from, to), from, to)
        }

        var resolved: [String: [LatLng]] = [:]
        var missingPairs: [(key: String, from: Place, to: Place)] = []
        for pair in pairs {
            if let cached = routePolylineCache[pair.key] {
                resolved[pair.key] = cached
            } else {
                missingPairs.append(pair)
            }
        }

        if !missingPairs.isEmpty {
            let fetched = await withTaskGroup(of: (String, [LatLng]?).self, returning: [(String, [LatLng])].self) { group in
                for pair in missingPairs {
                    group.addTask {
                        let result = await store.currentEngine.getDirections(
                            from: LatLng(lat: pair.from.lat, lng: pair.from.lng),
                            to: LatLng(lat: pair.to.lat, lng: pair.to.lng),
                            mode: .DRIVING
                        )
                        guard let result else { return (pair.key, nil) }
                        let polyline = result.polyline.isEmpty
                            ? [LatLng(lat: pair.from.lat, lng: pair.from.lng), LatLng(lat: pair.to.lat, lng: pair.to.lng)]
                            : result.polyline
                        return (pair.key, polyline)
                    }
                }

                var results: [(String, [LatLng])] = []
                for await (key, polyline) in group {
                    if Task.isCancelled { return [] }
                    guard let polyline else { continue }
                    results.append((key, polyline))
                }
                return results
            }

            if Task.isCancelled { return }
            for (key, polyline) in fetched {
                resolved[key] = polyline
                routePolylineCache[key] = polyline
            }
        }

        let validKeys = Set(pairs.map(\.key))
        routePolylineCache = routePolylineCache.filter { validKeys.contains($0.key) }
        if Task.isCancelled { return }
        routePolylines = resolved
    }

}

