import SwiftUI

// Native editor entry point. Holds a NoteBlockController which acts as the
// editing SoT for the open note; NoteStore remains the long-term SoT and
// the controller debounces saves through NoteDocumentBridge.
struct NativeNoteEditor: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String
    let isLocked: Bool
    let onTapPlace: (String) -> Void
    /// Optional out-binding so a parent (typically EditModeView) can keep
    /// a reference to the live controller and dispatch toolbar commands.
    @Binding var controllerRef: NoteBlockController?

    init(
        noteID: String,
        isLocked: Bool,
        controllerRef: Binding<NoteBlockController?> = .constant(nil),
        onTapPlace: @escaping (String) -> Void
    ) {
        self.noteID = noteID
        self.isLocked = isLocked
        self._controllerRef = controllerRef
        self.onTapPlace = onTapPlace
    }

    @State private var controller: NoteBlockController?
    @State private var copyToastVisible = false

    private var note: Note? {
        store.notes.first(where: { $0.id == noteID })
    }

    var body: some View {
        Group {
            if let controller {
                editorBody(controller: controller)
            } else {
                Color.clear.onAppear { bootstrapController() }
            }
        }
        .onChange(of: noteID) { _, _ in bootstrapController() }
        .onDisappear { controller?.flushPendingSave() }
    }

    private func editorBody(controller: NoteBlockController) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                scrollContent(controller: controller)

                if controller.isMultiSelecting {
                    VStack {
                        Spacer()
                        SelectionActionBar(
                            count: controller.selectedIDs.count,
                            onCopy: {
                                if controller.copySelectedToPasteboard() {
                                    copyToastVisible = true
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                                        copyToastVisible = false
                                    }
                                }
                            },
                            onDelete: { controller.deleteSelected() },
                            onCancel: { controller.enterDisplay() }
                        )
                        .padding(.bottom, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if copyToastVisible {
                    Text("已复制")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 84)
                        .transition(.opacity)
                }

                if let menu = controller.slashMenu {
                    slashMenuOverlay(menu: menu, in: geo, controller: controller)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: controller.isMultiSelecting)
            .animation(.easeInOut(duration: 0.2), value: copyToastVisible)
        }
    }

    /// Positions the slash menu using the caret's window-space rect that the
    /// Coordinator forwarded. We convert into the editor's local frame via
    /// the surrounding GeometryReader, then nudge so the menu never overlaps
    /// the keyboard or the top of the editor.
    private func slashMenuOverlay(
        menu: NoteBlockController.SlashMenuState,
        in geo: GeometryProxy,
        controller: NoteBlockController
    ) -> some View {
        let editorFrame = geo.frame(in: .global)
        let anchor = menu.anchorInWindow
        let menuWidth: CGFloat = 240
        let menuHeight: CGFloat = 300
        var localX = anchor.midX - editorFrame.minX
        var localY = anchor.maxY - editorFrame.minY + 6
        // Keep within editor bounds.
        let halfW = menuWidth / 2
        localX = max(halfW + 8, min(editorFrame.width - halfW - 8, localX))
        let maxYTop = editorFrame.height - menuHeight - 12
        if localY > maxYTop {
            // Flip above the caret if there isn't room below.
            localY = max(8, anchor.minY - editorFrame.minY - menuHeight - 6)
        }
        return SlashMenuView(
            query: menu.query,
            onSelect: { controller.commitSlashOption($0) },
            onDismiss: { controller.dismissSlashMenu() }
        )
        .position(x: localX, y: localY + menuHeight / 2)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func scrollContent(controller: NoteBlockController) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let blocks = controller.document
                let orderedIndices = computeOrderedIndices(blocks)
                let selected = controller.selectedIDs
                let dragState = controller.dragState
                let draggingIDs = Set(dragState?.blockIDs ?? [])
                let mode = controller.mode

                ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                    NoteBlockEditableRowView(
                        block: block,
                        orderedIndex: orderedIndices[idx],
                        isLocked: isLocked,
                        mode: mode,
                        isSelected: selected.contains(block.id),
                        isBeingDragged: draggingIDs.contains(block.id),
                        dropLineAbove: dragState?.beforeBlockID == block.id,
                        controller: controller,
                        pendingFocus: controller.focusRequest,
                        onTapPlace: onTapPlace
                    )
                }
                if dragState != nil, dragState?.beforeBlockID == nil {
                    Rectangle()
                        .fill(AppTheme.primary)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .transition(.opacity)
                }
                // Tail spacer absorbs taps on blank area below the last
                // block. In multi-select it exits selection; in editing it
                // drops focus; in display it appends a new paragraph and
                // enters editing.
                Color.clear
                    .frame(height: controller.isMultiSelecting ? 140 : 80)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleTailTap(controller: controller)
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.clear)
        .onPreferenceChange(BlockRowFramePreference.self) { frames in
            Task { @MainActor in
                // Replace map atomically so deleted rows clear out.
                controller.rowFrames = frames
            }
        }
    }

    private func handleTailTap(controller: NoteBlockController) {
        switch controller.mode {
        case .multiSelect:
            controller.enterDisplay()
        case .editing:
            controller.enterDisplay()
        case .display:
            // Append an empty paragraph and enter editing on it. Matches
            // every plain-text editor's "tap below the last line to keep
            // writing" expectation.
            guard !isLocked else { return }
            let id = NoteBlockID.make()
            controller.document.append(.paragraph(id: id, content: []))
            controller.enterEditing(blockID: id, offset: 0)
        }
    }

    private func bootstrapController() {
        guard let note else {
            controller = nil
            controllerRef = nil
            return
        }
        let document = NoteDocumentBridge.loadDocument(from: note)
        if let existing = controller {
            existing.resetIfNoteChanged(noteID: noteID, document: document)
        } else {
            controller = NoteBlockController(
                noteID: noteID,
                store: store,
                initial: document
            )
        }
        controllerRef = controller
    }

    private func computeOrderedIndices(_ blocks: NoteDocument) -> [Int?] {
        var result = [Int?](repeating: nil, count: blocks.count)
        var counterByLevel: [Int: Int] = [:]
        var lastOrderedByLevel: [Int: Bool] = [:]
        for (idx, block) in blocks.enumerated() {
            guard case .listItem(_, let kind, let level, _, _) = block else {
                counterByLevel.removeAll()
                lastOrderedByLevel.removeAll()
                continue
            }
            guard kind == .ordered else {
                counterByLevel[level] = nil
                lastOrderedByLevel[level] = false
                continue
            }
            if lastOrderedByLevel[level] == true, let n = counterByLevel[level] {
                counterByLevel[level] = n + 1
            } else {
                counterByLevel[level] = 1
            }
            lastOrderedByLevel[level] = true
            result[idx] = counterByLevel[level]
        }
        return result
    }
}
