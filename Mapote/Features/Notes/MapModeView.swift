import SwiftUI
import MapKit

struct MapBackgroundView: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String
    let isLocked: Bool
    let visiblePlaceIDs: Set<String>?
    let focusTrigger: Int
    let occludedBottomHeight: CGFloat
    let viewportHeight: CGFloat

    @State private var position: MapCameraPosition = .automatic
    @State private var selectedPlace: Place?
    @State private var routePolylines: [String: [LatLng]] = [:]
    @State private var routePolylineCache: [String: [LatLng]] = [:]

    private var note: Note? { store.notes.first(where: { $0.id == noteID }) }

    private var allOrderedPlaces: [Place] {
        guard let note else { return [] }
        let ordered = MarkdownService.orderedPlaces(note: note)
        return ordered.isEmpty ? note.places : ordered
    }

    private var orderedPlaces: [Place] {
        guard let visiblePlaceIDs else { return allOrderedPlaces }
        return allOrderedPlaces.filter { place in
            visiblePlaceIDs.contains(place.id) || visiblePlaceIDs.contains(place.placeId ?? "")
        }
    }

    private var routeTaskKey: String {
        let ids = orderedPlaces.map(\.id).joined(separator: "|")
        return "\(store.mapSettings.showRoute)|\(ids)"
    }
    private var occlusionRatio: CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let rawRatio = occludedBottomHeight / viewportHeight
        return min(max(rawRatio, 0), 0.82)
    }

    private var visibleHeightFraction: Double {
        max(1 - Double(occlusionRatio), 0.18)
    }

    private var mapKitStyle: MapStyle {
        switch store.mapSettings.theme {
        case "dark", "night":
            return .imagery(elevation: .realistic)
        default:
            return .standard(
                elevation: .flat,
                emphasis: store.mapSettings.emphasis == "muted" ? .muted : .automatic,
                showsTraffic: store.mapSettings.showTraffic
            )
        }
    }

    private var markerTint: Color { Color(hex: "#54c2f8") }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mapLayer
                .ignoresSafeArea()

            if let mapEngineError = store.mapEngineError {
                Text(mapEngineError)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.18))
                    .clipShape(Capsule())
                    .padding(.trailing, 14)
                    .padding(.top, 60)
            }
        }
        .onAppear { fitBounds(animated: false) }
        .onChange(of: orderedPlaces) { _, _ in fitBounds() }
        .onChange(of: focusTrigger) { _, _ in fitBounds() }
        .onChange(of: occludedBottomHeight) { _, _ in fitBounds() }
        .onChange(of: viewportHeight) { _, _ in fitBounds() }
        .task(id: routeTaskKey) {
            await loadRoutePolylines()
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
    }

    private var mapLayer: some View {
        Map(position: $position, selection: $selectedPlace) {
            ForEach(Array(orderedPlaces.enumerated()), id: \.element.id) { idx, place in
                if store.mapSettings.poiToggles[place.category ?? .other] ?? true {
                    Annotation(
                        store.mapSettings.showName ? place.name : "",
                        coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
                    ) {
                        let isSelected = selectedPlace?.id == place.id
                        ZStack {
                            Circle()
                                .fill(markerTint)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                }
                            if store.mapSettings.showNumber {
                                Text("\(idx + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .scaleEffect(isSelected ? 1.24 : 1.0)
                        .animation(.spring(response: 0.24, dampingFraction: 0.68), value: isSelected)
                        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
                    }
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
                        .stroke(Color(hex: "#53bded"), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: coords)
                        .stroke(Color(hex: "#7ad3f6"), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .mapStyle(mapKitStyle)
        .mapControlVisibility(.hidden)
    }

    private func fitBounds(animated: Bool = true) {
        guard let nextPosition = makeFittedPosition() else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                position = nextPosition
            }
        } else {
            position = nextPosition
        }
    }

    private func makeFittedPosition() -> MapCameraPosition? {
        guard !orderedPlaces.isEmpty else { return nil }

        if orderedPlaces.count == 1, let first = orderedPlaces.first {
            var region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng),
                latitudinalMeters: 1500 / visibleHeightFraction,
                longitudinalMeters: 1500
            )
            region.center = adjustedCenter(region.center, latitudeDelta: region.span.latitudeDelta)
            return .region(region)
        }

        let lats = orderedPlaces.map(\.lat)
        let lngs = orderedPlaces.map(\.lng)
        guard
            let minLat = lats.min(),
            let maxLat = lats.max(),
            let minLng = lngs.min(),
            let maxLng = lngs.max()
        else {
            return nil
        }

        let latDelta = max((maxLat - minLat) * 1.6 / visibleHeightFraction, 0.02)
        let lngDelta = max((maxLng - minLng) * 1.6, 0.02)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let adjusted = adjustedCenter(center, latitudeDelta: latDelta)

        return .region(MKCoordinateRegion(
            center: adjusted,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
        ))
    }

    private func adjustedCenter(
        _ center: CLLocationCoordinate2D,
        latitudeDelta: CLLocationDegrees
    ) -> CLLocationCoordinate2D {
        let latitudeShift = latitudeDelta * CLLocationDegrees(occlusionRatio) * 0.5
        let adjustedLat = min(max(center.latitude - latitudeShift, -85), 85)
        return CLLocationCoordinate2D(latitude: adjustedLat, longitude: center.longitude)
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
