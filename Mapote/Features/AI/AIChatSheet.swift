import SwiftUI

struct AIChatSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let noteID: String

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var streaming = false
    @State private var placeGroupsByMessage: [String: [AIPlaceGroup]] = [:]
    @State private var addedPlaces: Set<String> = []
    @State private var addingGroups: Set<String> = []
    @State private var groupProgress: [String: Int] = [:]
    @State private var groupTotal: [String: Int] = [:]
    @State private var groupFailures: [String: Int] = [:]

    private var note: Note? { store.notes.first(where: { $0.id == noteID }) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if messages.isEmpty {
                            quickPrompts
                        }
                        ForEach(messages) { msg in
                            messageBubble(msg)
                        }
                    }
                    .padding(12)
                }
                inputBar
            }
            .navigationBarBackButtonHidden()
            .task {
                messages = store.chatMessages(for: noteID)
                for msg in messages where msg.role == .assistant {
                    placeGroupsByMessage[msg.id] = AIParsingService.parsePlaceBlocks(msg.content)
                }
            }
            .onChange(of: messages) { _, newValue in
                if !streaming {
                    store.saveChatMessages(newValue, noteID: noteID)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("🗺️ AI 旅行助手").font(.headline)
                Text("帮你推荐目的地和规划行程").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
        }
        .padding(12)
        .background(AppTheme.paper)
    }

    private var quickPrompts: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["推荐东京三天行程", "巴黎有哪些必去的地方", "帮我规划京都一日游"], id: \.self) { prompt in
                Button(prompt) { input = prompt }
                    .buttonStyle(.mapoteSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 8) {
            Text(msg.role == .assistant ? cleanedAssistantText(msg.content) : msg.content)
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
                .padding(10)
                .background(msg.role == .user ? AppTheme.primary : AppTheme.muted)
                .foregroundStyle(msg.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if msg.role == .assistant, let groups = placeGroupsByMessage[msg.id], !groups.isEmpty {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.title).font(.subheadline.bold())
                            Spacer()
                            Button(addAllButtonTitle(for: group)) {
                                Task { await addGroup(group) }
                            }
                            .buttonStyle(.mapoteSecondary)
                            .disabled(addingGroups.contains(groupKey(group)))
                        }
                        if let fail = groupFailures[groupKey(group)], fail > 0, !addingGroups.contains(groupKey(group)) {
                            Text("有 \(fail) 个地点未找到匹配，已跳过")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !group.intro.isEmpty {
                            Text(group.intro).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(group.places) { card in
                            placeCard(card)
                        }
                    }
                    .padding(10)
                    .background(AppTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func placeCard(_ card: AIPlaceCard) -> some View {
        HStack(spacing: 10) {
            AIPlaceThumbnail(searchQuery: card.searchQuery)
                .environmentObject(store)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name).font(.subheadline.bold())
                if let reason = card.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if let tips = card.tips { Text(tips).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Button {
                Task { await addSinglePlace(card) }
            } label: {
                Image(systemName: addedPlaces.contains(card.id) ? "checkmark" : "plus")
            }
            .buttonStyle(.mapotePrimary)
            .disabled(addedPlaces.contains(card.id))
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("想去哪里旅行？", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button("发送") {
                Task { await send() }
            }
            .buttonStyle(.mapotePrimary)
            .disabled(streaming || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() async {
        let user = ChatMessage(role: .user, content: input)
        messages.append(user)
        input = ""
        streaming = true
        var assistant = ChatMessage(role: .assistant, content: "")
        messages.append(assistant)

        do {
            let full = try await GeminiService.shared.chatStream(
                messages: messages,
                noteContext: note?.places.map(\.name) ?? [],
                onChunk: { chunk in
                    if let idx = messages.firstIndex(where: { $0.id == assistant.id }) {
                        messages[idx].content = chunk
                    }
                }
            )
            assistant.content = full
            if let idx = messages.firstIndex(where: { $0.id == assistant.id }) {
                messages[idx] = assistant
            }
            placeGroupsByMessage[assistant.id] = AIParsingService.parsePlaceBlocks(full)
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == assistant.id }) {
                messages[idx].content = "当前未配置 Gemini API Key，无法使用 AI 对话。"
            }
        }
        streaming = false
    }

    private func addSinglePlace(_ card: AIPlaceCard) async {
        guard let hit = await store.currentEngine.findPlace(
            query: card.searchQuery,
            options: SearchOptions(locationBias: note?.places.averageLatLng, radius: 50000, city: nil)
        ) else { return }
        var name = hit.name
        if !card.name.isEmpty && card.name.isCJK && !name.isCJK {
            name = card.name
        }
        let noteText = [card.reason, card.tips].compactMap { $0 }.joined(separator: "。")
        let place = Place(
            name: name,
            address: hit.address,
            lat: hit.lat,
            lng: hit.lng,
            note: noteText,
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
        let insert = "\n::place[\(name)]{#\(place.id)}\n\(noteText)"
        store.upsertPlace(noteID: noteID, place: place, insertText: insert)
        addedPlaces.insert(card.id)
    }

    private func addGroup(_ group: AIPlaceGroup) async {
        let key = groupKey(group)
        addingGroups.insert(key)
        groupProgress[key] = 0
        groupTotal[key] = group.places.count
        groupFailures[key] = 0

        var markdown = "\n# \(group.title)\n"
        if !group.intro.isEmpty { markdown += "\(group.intro)\n" }
        var added: [Place] = []
        for card in group.places {
            guard let hit = await store.currentEngine.findPlace(query: card.searchQuery, options: SearchOptions(locationBias: note?.places.averageLatLng, radius: 50000, city: nil)) else {
                groupFailures[key, default: 0] += 1
                groupProgress[key, default: 0] += 1
                continue
            }
            let noteText = [card.reason, card.tips].compactMap { $0 }.joined(separator: "。")
            let place = Place(
                name: card.name,
                address: hit.address,
                lat: hit.lat,
                lng: hit.lng,
                note: noteText,
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
            markdown += "\n::place[\(place.name)]{#\(place.id)}\n\(noteText)\n"
            added.append(place)
            addedPlaces.insert(card.id)
            groupProgress[key, default: 0] += 1
        }
        store.appendItinerary(noteID: noteID, markdown: markdown, places: added)
        addingGroups.remove(key)
    }

    private func cleanedAssistantText(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: #"```json:places\s*[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func groupKey(_ group: AIPlaceGroup) -> String {
        "\(group.title)|\(group.places.map(\.id).joined(separator: ","))"
    }

    private func addAllButtonTitle(for group: AIPlaceGroup) -> String {
        let key = groupKey(group)
        if addingGroups.contains(key) {
            let done = groupProgress[key, default: 0]
            let total = groupTotal[key, default: max(1, group.places.count)]
            return "添加中 \(done)/\(total)"
        }
        return "全部添加"
    }
}

private struct AIPlaceThumbnail: View {
    @EnvironmentObject private var store: NoteStore
    let searchQuery: String
    @State private var url: String?
    @State private var loading = false

    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                    @unknown default:
                        Image(systemName: "photo")
                    }
                }
            } else if loading {
                ProgressView()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 40, height: 40)
        .background(AppTheme.muted)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: searchQuery) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        if let cached = await ThumbnailCache.shared.get(searchQuery) {
            url = cached
            return
        }
        loading = true
        defer { loading = false }
        guard let place = await store.currentEngine.findPlace(query: searchQuery, options: nil),
              let photoURL = place.photoUrl else {
            return
        }
        await ThumbnailCache.shared.set(searchQuery, url: photoURL)
        url = photoURL
    }
}

