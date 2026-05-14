import SwiftUI

// One block row. All gesture coordination flows through `controller.mode`:
//
//   • display       — long-press → drag this block; swipe → multi-select
//   • editing       — caret + keyboard live on the inner UITextView;
//                     long-press / swipe still allowed and they will exit
//                     editing first (controller drops focus)
//   • multiSelect   — taps toggle, long-press a selected block drags the
//                     whole selection, long-press an unselected block
//                     exits multi-select and drags just that one
//
// The row also publishes its window-space frame via a PreferenceKey so the
// container can build a row-frame map for the drop indicator math.
struct NoteBlockEditableRowView: View {
    let block: NoteBlock
    let orderedIndex: Int?
    let isLocked: Bool
    let mode: NoteBlockController.Mode
    let isSelected: Bool
    let isBeingDragged: Bool
    let dropLineAbove: Bool
    let controller: NoteBlockController
    let pendingFocus: NoteBlockController.FocusRequest?
    let onTapPlace: (String) -> Void

    @GestureState private var longPressArmed: Bool = false

    private var isMultiSelecting: Bool {
        if case .multiSelect = mode { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .background(selectionBackground)
                .opacity(isBeingDragged ? 0.35 : 1)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BlockRowFramePreference.self,
                            value: [block.id: proxy.frame(in: .global)]
                        )
                    }
                )

            // In multi-select mode the entire row toggles selection on tap.
            // BlockTextView's own tap recognizer also handles this, but the
            // overlay covers list markers / image rows / dividers too.
            if isMultiSelecting {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { controller.toggleSelection(block.id) }
            }

            if dropLineAbove {
                Rectangle()
                    .fill(AppTheme.primary)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: -1)
            }
        }
        .overlay(alignment: .trailing) {
            if isMultiSelecting {
                selectionDot.padding(.trailing, 6)
            }
        }
        .simultaneousGesture(swipeGesture)
        .simultaneousGesture(longPressDragGesture)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: dropLineAbove)
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .paragraph(let id, let content):
            blockText(id: id, content: content, style: .paragraph)
                .padding(.vertical, 4)
        case .heading(let id, let level, let content):
            blockText(id: id, content: content, style: .heading(level: level))
                .padding(.top, level == 1 ? 12 : 8)
                .padding(.bottom, 4)
        case .listItem(let id, let kind, let level, let checked, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                listMarker(kind: kind, checked: checked)
                    .frame(minWidth: 18, alignment: .trailing)
                blockText(id: id, content: content, style: .listItem)
            }
            .padding(.leading, CGFloat(level) * 18)
            .padding(.vertical, 3)
        case .divider:
            Divider().padding(.vertical, 8)
        case .image(_, let url):
            ImageRow(url: url).padding(.vertical, 6)
        }
    }

    private func blockText(
        id: String,
        content: [InlineRun],
        style: BlockAttributedString.Style
    ) -> some View {
        BlockTextView(
            blockID: id,
            content: content,
            style: style,
            isEditable: !isLocked,
            mode: mode,
            pendingFocus: pendingFocus,
            controller: controller
        )
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.primary.opacity(0.5), lineWidth: 1.5)
                )
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
        } else {
            Color.clear
        }
    }

    private var selectionDot: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AppTheme.primary : Color.white)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? AppTheme.primary : AppTheme.foregroundSoft.opacity(0.5),
                            lineWidth: 2
                        )
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
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
            Button {
                if !isMultiSelecting {
                    controller.toggleTaskChecked(block.id)
                }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(checked ? AppTheme.primary : AppTheme.foregroundSoft)
            }
            .buttonStyle(.plain)
            .disabled(isMultiSelecting || isLocked)
        }
    }

    // MARK: - Gestures

    /// Horizontal swipe → enter multi-select. Allowed from display *and*
    /// editing modes (editing → multi-select drops the caret).
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                if case .multiSelect = mode { return }
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)
                let dominant = dx > dy * 1.3
                let crossed = dx > 32
                if dominant, crossed {
                    controller.enterMultiSelect(with: block.id)
                }
            }
    }

    /// Long-press → drag. The press fires from any mode; the controller
    /// figures out which blocks travel with the drag (see `beginDrag`).
    private var longPressDragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($longPressArmed) { value, state, _ in
                switch value {
                case .first(true), .second(true, _): state = true
                default: state = false
                }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if controller.dragState == nil {
                    controller.beginDrag(blockID: block.id, at: drag.location)
                } else {
                    controller.updateDrag(pointer: drag.location)
                }
            }
            .onEnded { _ in
                if controller.dragState != nil {
                    controller.endDrag(commit: true)
                }
            }
    }
}

/// Per-row window-space frame published upstream so the container can map
/// pointer positions onto block ids without each row knowing about its
/// siblings.
struct BlockRowFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ImageRow: View {
    let url: String

    var body: some View {
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
    }

    private func placeholder(_ text: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.paper)
            .frame(height: 140)
            .overlay(Text(text).font(.caption).foregroundStyle(AppTheme.foregroundSoft))
    }
}
