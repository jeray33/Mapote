import SwiftUI

struct NoteListScreen: View {
    @EnvironmentObject private var store: NoteStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                if store.notes.isEmpty {
                    ScrollView {
                        emptyState
                            .padding(.horizontal, 16)
                            .padding(.top, 28)
                    }
                } else {
                    List {
                        ForEach(store.notes) { note in
                            NoteCard(
                                note: note,
                                onSelect: {
                                    store.select(noteID: note.id)
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
            }
            .safeAreaInset(edge: .top) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .background(AppTheme.background.ignoresSafeArea())
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(AppTheme.primary)
                Text("地点笔记")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.foreground)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.paper.opacity(0.82))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("应用配置")
            .accessibilityHint("打开应用配置与地图设置")

            Button {
                store.createNoteAndOpen()
            } label: {
                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    var body: some View {
        HStack(spacing: 14) {
            imageStack
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(note.title.isEmpty ? "未命名笔记" : note.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 4) {
                    Text("\(orderedPlaces.count) 个地点")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(AppTheme.foregroundSoft)
                flowTags
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadow, radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            onSelect()
        }
    }

    private var imageStack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(previewPlaces.enumerated()), id: \.offset) { idx, place in
                Group {
                    if let url = preferredImageURL(for: place) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                RoundedRectangle(cornerRadius: 10).fill(AppTheme.muted).overlay { ProgressView().scaleEffect(0.7) }
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                RoundedRectangle(cornerRadius: 10).fill(AppTheme.muted).overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                            @unknown default:
                                RoundedRectangle(cornerRadius: 10).fill(AppTheme.muted)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.muted)
                            .overlay {
                                Image(systemName: (place.category ?? .other).sfSymbol)
                                    .foregroundStyle((place.category ?? .other).color)
                            }
                    }
                }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
                    )
                    .offset(x: CGFloat(idx) * 5, y: CGFloat(idx) * 5)
            }
            if previewPlaces.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppTheme.muted)
                    .frame(width: 60, height: 60)
            }
        }
        .frame(width: 80, height: 80)
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

    private var flowTags: some View {
        let names = orderedPlaces.prefix(4).map(\.name)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.secondary)
                        .foregroundStyle(AppTheme.foreground)
                        .clipShape(Capsule())
                }
                if orderedPlaces.count > 4 {
                    Text("+\(orderedPlaces.count - 4)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.foregroundSoft)
                }
            }
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return "更新于 \(formatter.string(from: Date(timeIntervalSince1970: note.updatedAt / 1000)))"
    }
}

