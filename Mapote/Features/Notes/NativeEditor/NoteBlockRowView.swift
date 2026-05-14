import SwiftUI

// One read-only row in the native editor. Editing-capable rows arrive in
// Phase 3 as a UITextView-backed sibling. Keeping the read-only path as
// pure SwiftUI lets us validate visual parity with the WebView in
// isolation before introducing the input pipeline.
struct NoteBlockRowView: View {
    let block: NoteBlock
    let orderedIndex: Int?
    let onTapPlace: (String) -> Void

    var body: some View {
        Group {
            switch block {
            case .paragraph(_, let content):
                paragraph(content)
            case .heading(_, let level, let content):
                heading(level: level, content: content)
            case .listItem(_, let kind, let level, let checked, let content):
                listItem(kind: kind, level: level, checked: checked, content: content)
            case .divider:
                Divider().padding(.vertical, 8)
            case .image(_, let url):
                imageBlock(url: url)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let id = InlineRunAttributedString.extractPlaceID(from: url) {
                onTapPlace(id)
                return .handled
            }
            return .systemAction
        })
    }

    private func paragraph(_ content: [InlineRun]) -> some View {
        Text(InlineRunAttributedString.make(content))
            .font(.system(size: 17))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func heading(level: Int, content: [InlineRun]) -> some View {
        let font: Font = {
            switch level {
            case 1: return .system(size: 26, weight: .bold)
            case 2: return .system(size: 22, weight: .bold)
            default: return .system(size: 18, weight: .semibold)
            }
        }()
        return Text(InlineRunAttributedString.make(content))
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, level == 1 ? 12 : 8)
            .padding(.bottom, 4)
    }

    private func listItem(
        kind: BlockListKind,
        level: Int,
        checked: Bool,
        content: [InlineRun]
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            listMarker(kind: kind, checked: checked)
                .frame(minWidth: 18, alignment: .trailing)
            Text(InlineRunAttributedString.make(content))
                .font(.system(size: 17))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(level) * 18)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func listMarker(kind: BlockListKind, checked: Bool) -> some View {
        switch kind {
        case .bullet:
            Text("•")
                .font(.system(size: 17))
                .foregroundStyle(AppTheme.foregroundSoft)
        case .ordered:
            Text("\(orderedIndex ?? 1).")
                .font(.system(size: 17))
                .foregroundStyle(AppTheme.foregroundSoft)
        case .task:
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AppTheme.primary : AppTheme.foregroundSoft)
        }
    }

    private func imageBlock(url: String) -> some View {
        let resolved: URL? = {
            guard let parsed = URL(string: url) else { return nil }
            if parsed.scheme == EditorImageStorage.scheme {
                return EditorImageStorage.fileURL(for: parsed)
            }
            return parsed
        }()
        return AsyncImage(url: resolved) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .failure:
                placeholder("图片加载失败")
            case .empty:
                placeholder("加载中…")
            @unknown default:
                placeholder("图片")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func placeholder(_ text: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.paper)
            .frame(height: 140)
            .overlay(Text(text).font(.caption).foregroundStyle(AppTheme.foregroundSoft))
    }
}
