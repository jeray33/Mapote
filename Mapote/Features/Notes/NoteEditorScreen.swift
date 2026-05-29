import SwiftUI
import UIKit

struct NoteEditorScreen: View {
    @EnvironmentObject private var store: NoteStore
    let noteID: String

    @State private var mode: ViewMode = .note
    @State private var isLocked = false
    @State private var sheetDetent: PresentationDetent = .large
    @State private var didSetInitialDetent = false
    @State private var listSectionIndex = 0
    @State private var mapFocusTrigger = 0
    @State private var editorMode: String = "display"
    @State private var editorFlushRequest: EditorFlushRequest?
    @State private var pendingEditorFlush: PendingEditorFlush?

    private static let collapsedDetentHeight: CGFloat = 64

    private enum EditorFlushAction: Equatable {
        case backToNotes
        case showList
    }

    private struct PendingEditorFlush: Equatable {
        let requestID: UUID
        let action: EditorFlushAction
    }

    private var note: Note? {
        store.notes.first(where: { $0.id == noteID })
    }

    private var listSections: [MarkdownService.Section] {
        guard let note else { return [] }
        return MarkdownService.getPlacesBySection(note: note)
    }

    private var mapVisiblePlaceIDs: Set<String>? {
        guard mode == .list else { return nil }
        guard !listSections.isEmpty else { return nil }
        guard listSectionIndex > 0, listSections.indices.contains(listSectionIndex - 1) else { return nil }
        return Set(listSections[listSectionIndex - 1].placeIDs)
    }

    private var editorOwnsGestures: Bool {
        // Editing should not freeze the native sheet. Block drag and
        // multi-select are currently paused in the Web editor, so this only
        // remains as a safety boundary if those modes are re-enabled later.
        mode == .note && ["multiSelect", "dragging"].contains(editorMode)
    }

    private var activeSheetDetents: Set<PresentationDetent> {
        editorOwnsGestures ? [sheetDetent] : [.height(Self.collapsedDetentHeight), .medium, .large]
    }

    var body: some View {
        if let note {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    MapBackgroundView(
                        noteID: noteID,
                        isLocked: isLocked,
                        visiblePlaceIDs: mapVisiblePlaceIDs,
                        focusTrigger: mapFocusTrigger,
                        occludedBottomHeight: mapOccludedHeight(
                            screenHeight: proxy.size.height,
                            safeBottom: proxy.safeAreaInsets.bottom
                        ),
                        viewportHeight: proxy.size.height
                    )
                        .environmentObject(store)

                    topMapBlurOverlay

                    floatingBackButton
                        .padding(.leading, 12)
                        .padding(.top, 8)

                    floatingFocusButton(screenHeight: proxy.size.height, safeBottom: proxy.safeAreaInsets.bottom)
                }
                .background(AppTheme.background.ignoresSafeArea())
            }
            .sheet(isPresented: .constant(true)) {
                sheetBody
                    .presentationDetents(
                        activeSheetDetents,
                        selection: $sheetDetent
                    )
                    .presentationDragIndicator(editorOwnsGestures ? .hidden : .visible)
                    .presentationBackgroundInteraction(editorOwnsGestures ? .disabled : .enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                    .interactiveDismissDisabled(true)
            }
            .onAppear {
                guard !didSetInitialDetent else { return }
                if note.places.isEmpty {
                    // 先以中等高度出现，再补一段过渡到满屏，保证新建/无地点笔记也有进入动效。
                    sheetDetent = .medium
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            sheetDetent = .large
                        }
                    }
                } else {
                    sheetDetent = .medium
                }
                didSetInitialDetent = true
            }
            .task(id: noteID) {
                await store.fillMissingPlaceCoversFromAmap(noteID: noteID)
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .note {
                    listSectionIndex = 0
                }
            }
            .onChange(of: listSections.count) { _, _ in
                if listSections.isEmpty {
                    listSectionIndex = 0
                } else if listSectionIndex > listSections.count {
                    listSectionIndex = 0
                }
            }
        }
    }

    @ViewBuilder
    private var topMapBlurOverlay: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 180)
            .mask(
                LinearGradient(
                    colors: [.black.opacity(0.95), .black.opacity(0.22), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var sheetBody: some View {
        if let currentNote = note {
            VStack(spacing: 0) {
                if mode == .note {
                    titleBar(note: currentNote)
                    ZStack(alignment: .bottomTrailing) {
                        EditModeView(
                            noteID: noteID,
                            isLocked: $isLocked,
                            flushRequest: $editorFlushRequest,
                            onEditorModeChanged: { nextMode, _ in
                                editorMode = nextMode
                            },
                            onContentFlush: { requestID in
                                completeEditorFlush(requestID: requestID)
                            }
                        )
                        .environmentObject(store)
                    }
                } else {
                    ListModeView(
                        noteID: noteID,
                        sectionIndex: $listSectionIndex,
                        onToggleMode: { toggleMode() }
                    )
                        .environmentObject(store)
                }
            }
            .background(AppTheme.background)
        } else {
            EmptyView()
        }
    }

    private var floatingBackButton: some View {
        Button {
            requestEditorFlushThen(.backToNotes)
        } label: {
            Image(systemName: "chevron.left")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 42, height: 42)
                .background(AppTheme.paper)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                .shadow(color: AppTheme.shadow, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回笔记列表")
    }

    private func titleBar(note: Note) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("笔记标题", text: Binding(
                get: { note.title },
                set: { store.updateTitle(noteID: noteID, title: $0) }
            ))
            .font(.title2.weight(.bold))
            .textFieldStyle(.plain)
            .foregroundStyle(AppTheme.foreground)
            .disabled(isLocked)

            // noteMoreMenu
            modeToggleButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(UIColor.separator).opacity(0.6))
                .frame(height: 0.5)
        }
    }

//    private var noteMoreMenu: some View {
//        Menu {
//            Button {
//                isLocked.toggle()
//            } label: {
//                Label(isLocked ? "解锁编辑" : "锁定编辑", systemImage: isLocked ? "lock.open" : "lock.fill")
//            }
//        } label: {
//            Image(systemName: "ellipsis")
//                .font(.headline.weight(.semibold))
//                .foregroundStyle(AppTheme.foreground)
//                .frame(width: 36, height: 36)
//                .background(AppTheme.paper)
//                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
//                .overlay(
//                    RoundedRectangle(cornerRadius: 10, style: .continuous)
//                        .stroke(AppTheme.border, lineWidth: 1)
//                )
//        }
//        .accessibilityLabel("更多操作")
//    }

    private var modeToggleButton: some View {
        Button(action: toggleMode) {
            toolbarIcon(mode == .note ? "list.bullet" : "pencil.line")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .note ? "切换到列表模式" : "切换到笔记模式")
    }

    private func toggleMode() {
        if mode == .note {
            requestEditorFlushThen(.showList)
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            mode = .note
        }
    }

    private func requestEditorFlushThen(_ action: EditorFlushAction) {
        guard mode == .note else {
            performEditorFlushAction(action)
            return
        }
        let request = EditorFlushRequest()
        pendingEditorFlush = PendingEditorFlush(requestID: request.id, action: action)
        editorFlushRequest = request
    }

    private func completeEditorFlush(requestID: UUID) {
        guard let pending = pendingEditorFlush, pending.requestID == requestID else { return }
        pendingEditorFlush = nil
        performEditorFlushAction(pending.action)
    }

    private func performEditorFlushAction(_ action: EditorFlushAction) {
        switch action {
        case .backToNotes:
            let collapsed = PresentationDetent.height(Self.collapsedDetentHeight)
            if sheetDetent != collapsed {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sheetDetent = collapsed
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    store.select(noteID: nil)
                }
            } else {
                store.select(noteID: nil)
            }
        case .showList:
            withAnimation(.easeOut(duration: 0.18)) {
                mode = .list
            }
        }
    }

    private func floatingFocusButton(screenHeight: CGFloat, safeBottom: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if sheetDetent != .large {
                    Button {
                        mapFocusTrigger += 1
                    } label: {
                        Image(systemName: "viewfinder")
                            .font(.headline)
                            .foregroundStyle(AppTheme.foreground)
                            .frame(width: 42, height: 42)
                            .background(AppTheme.paper)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到地点中心")
                    .padding(.trailing, 14)
                    .padding(.bottom, focusButtonBottomPadding(screenHeight: screenHeight, safeBottom: safeBottom))
                }
            }
        }
    }

    private func focusButtonBottomPadding(screenHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        if sheetDetent == .medium {
            return max(screenHeight * 0.5, 260) + safeBottom + 18
        }
        return Self.collapsedDetentHeight + 18
    }

    private func mapOccludedHeight(screenHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        if sheetDetent == .large {
            return max(screenHeight * 0.5, 260)
        }
        return estimatedSheetHeight(screenHeight: screenHeight, safeBottom: safeBottom)
    }

    private func estimatedSheetHeight(screenHeight: CGFloat, safeBottom: CGFloat) -> CGFloat {
        if sheetDetent == .large {
            return max(screenHeight * 0.86, 340)
        }
        if sheetDetent == .medium {
            return max(screenHeight * 0.5, 260)
        }
        return Self.collapsedDetentHeight + safeBottom
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(AppTheme.foreground)
            .frame(width: 44, height: 44)
    }
}
