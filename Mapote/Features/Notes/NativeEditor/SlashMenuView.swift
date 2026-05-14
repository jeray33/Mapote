import SwiftUI

// Slash command popover. Surfaces block-type transformations whenever the
// focused block matches `/<query>` with no whitespace yet. Positioning is
// handled by NativeNoteEditor — this view is purely visual.
struct SlashMenuView: View {
    let query: String
    let onSelect: (NoteBlockController.SlashOption) -> Void
    let onDismiss: () -> Void

    private struct Entry: Identifiable {
        let id = UUID()
        let option: NoteBlockController.SlashOption
        let title: String
        let subtitle: String
        let icon: String
        let keywords: [String]
    }

    private static let entries: [Entry] = [
        Entry(option: .heading(1), title: "标题 H1", subtitle: "大标题", icon: "textformat.size.larger", keywords: ["h1", "heading", "title", "标题"]),
        Entry(option: .heading(2), title: "标题 H2", subtitle: "中标题", icon: "textformat.size", keywords: ["h2", "heading", "subtitle", "标题"]),
        Entry(option: .heading(3), title: "标题 H3", subtitle: "小标题", icon: "textformat.size.smaller", keywords: ["h3", "heading", "标题"]),
        Entry(option: .bulletList, title: "项目符号", subtitle: "无序列表", icon: "list.bullet", keywords: ["bullet", "list", "ul", "项目"]),
        Entry(option: .orderedList, title: "编号列表", subtitle: "有序列表", icon: "list.number", keywords: ["ordered", "number", "ol", "编号"]),
        Entry(option: .taskList, title: "待办事项", subtitle: "可勾选清单", icon: "checklist", keywords: ["task", "todo", "check", "待办"]),
        Entry(option: .divider, title: "分隔线", subtitle: "插入一条横线", icon: "minus", keywords: ["divider", "hr", "rule", "分隔"]),
        Entry(option: .paragraph, title: "正文", subtitle: "普通段落", icon: "text.alignleft", keywords: ["paragraph", "text", "正文"]),
    ]

    private var filtered: [Entry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Self.entries }
        return Self.entries.filter { entry in
            entry.title.lowercased().contains(q)
                || entry.subtitle.lowercased().contains(q)
                || entry.keywords.contains(where: { $0.hasPrefix(q) })
        }
    }

    var body: some View {
        let items = filtered
        return VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("无匹配命令")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.foregroundSoft)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { entry in
                            Button {
                                onSelect(entry.option)
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 18, y: 8)
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.primary.opacity(0.1))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(entry.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.foregroundSoft)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
