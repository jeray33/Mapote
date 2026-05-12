import SwiftUI

struct PlaceImageCarouselView: View {
    let imageURLs: [String]
    let height: CGFloat
    @State private var index = 0

    var body: some View {
        if imageURLs.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.muted)
                .frame(height: height)
                .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
        } else {
            VStack(spacing: 8) {
                TabView(selection: $index) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { idx, url in
                        AsyncImage(url: URL(string: url)) { phase in
                            switch phase {
                            case .empty:
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(AppTheme.muted)
                                    .overlay { ProgressView() }
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(AppTheme.muted)
                                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                            @unknown default:
                                RoundedRectangle(cornerRadius: 12).fill(AppTheme.muted)
                            }
                        }
                        .tag(idx)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(height: height)
                .tabViewStyle(.page(indexDisplayMode: .never))

                if imageURLs.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<imageURLs.count, id: \.self) { dot in
                            Circle()
                                .fill(dot == index ? AppTheme.primary : .secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
        }
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var data: [String: String] = [:]

    func get(_ key: String) -> String? { data[key] }
    func set(_ key: String, url: String) { data[key] = url }
}

