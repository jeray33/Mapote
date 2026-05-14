import Foundation
import SwiftUI

// Owns the live editing state for one open note. The store remains the
// long-term source of truth; this controller is the *editing* SoT and
// debounces writes back via NoteDocumentBridge so we don't re-serialize
// Markdown on every keystroke.
@MainActor
@Observable
final class NoteBlockController {
    /// Three top-level interaction modes. Every gesture is dispatched
    /// through this FSM — no mode-mixing inside row code.
    ///
    /// • `display` — read-only view of the document. No caret, no text
    ///   selection, no keyboard. Tap → editing. Long-press → drag the
    ///   tapped block. Swipe → multi-select.
    /// • `editing` — one block has the caret. Standard text input on
    ///   UITextView. Swipe / long-press leave editing first.
    /// • `multiSelect` — selection set is non-empty, blocks are inert,
    ///   action bar is mounted. Tap toggles, long-press a selected block
    ///   drags the whole selection (long-press an unselected block exits
    ///   multi-select and drags just that one block). Tap blank → display.
    enum Mode: Equatable {
        case display
        case editing(blockID: String)
        case multiSelect
    }

    var mode: Mode = .display
    var document: NoteDocument
    var focusRequest: FocusRequest?
    var focusedBlockID: String?
    /// Live caret + selection state for the focused block. Tracked so we can
    /// expose inline formatting commands (bold / italic) that operate on
    /// whatever the user has currently highlighted.
    var focusedSelection: SelectionRange?
    var selectedIDs: Set<String> = []
    /// Set to a non-nil value while a block is being dragged. Drives the
    /// row-level visuals (faded source, drop indicator line, etc.).
    var dragState: DragState?
    /// Slash command menu state. Driven by BlockTextView detecting a "/"
    /// prefix in the focused block; cleared on commit / dismiss.
    var slashMenu: SlashMenuState?
    /// Latest "@..." mention probe surfaced to the outer container so the
    /// existing EditModeView mention dropdown can light up.
    var mentionProbe: MentionProbe?
    /// Frames of every visible row in window coordinates. Reported by
    /// NoteBlockEditableRowView via a PreferenceKey. Used to (a) compute the
    /// drop indicator's insertion point and (b) translate caret rects.
    var rowFrames: [String: CGRect] = [:]

    var isMultiSelecting: Bool { mode == .multiSelect }

    func isEditing(blockID: String) -> Bool {
        if case .editing(let id) = mode { return id == blockID }
        return false
    }

    struct SelectionRange: Equatable {
        let blockID: String
        let location: Int
        let length: Int
    }

    struct SlashMenuState: Equatable {
        let blockID: String
        let query: String
        let anchorInWindow: CGRect
    }

    struct MentionProbe: Equatable {
        let blockID: String
        let query: String
        let anchorInWindow: CGRect
    }

    struct FocusRequest: Equatable {
        let blockID: String
        /// Character offset; `nil` means "place caret at end of block".
        let offset: Int?
    }

    struct DragState: Equatable {
        /// Blocks travelling with the drag (always at least one).
        let blockIDs: [String]
        /// Pointer position in window coordinates for the ghost element.
        var pointerLocation: CGPoint
        /// Block id immediately *before* the drop indicator; nil = top of doc.
        var beforeBlockID: String?
    }

    private(set) var noteID: String
    private weak var store: NoteStore?
    private var persistTask: Task<Void, Never>?
    private var hasUnsavedChanges = false

    init(noteID: String, store: NoteStore?, initial: NoteDocument) {
        self.noteID = noteID
        self.store = store
        self.document = initial.isEmpty
            ? [.paragraph(id: NoteBlockID.make(), content: [])]
            : initial
    }

    func resetIfNoteChanged(noteID: String, document: NoteDocument) {
        guard noteID != self.noteID else { return }
        persistTask?.cancel()
        hasUnsavedChanges = false
        selectedIDs = []
        dragState = nil
        focusRequest = nil
        slashMenu = nil
        mentionProbe = nil
        focusedBlockID = nil
        focusedSelection = nil
        rowFrames = [:]
        mode = .display
        self.noteID = noteID
        self.document = document.isEmpty
            ? [.paragraph(id: NoteBlockID.make(), content: [])]
            : document
    }

    // MARK: - Mode transitions

    /// Enter editing mode focused on a specific block. Idempotent — calling
    /// while already editing the same block is a no-op.
    func enterEditing(blockID: String, offset: Int? = nil) {
        if case .editing(let current) = mode, current == blockID, offset == nil { return }
        mode = .editing(blockID: blockID)
        selectedIDs = []
        focusRequest = FocusRequest(blockID: blockID, offset: offset)
    }

    /// Tap on blank space, end of multi-select, or after a drag completes.
    func enterDisplay() {
        mode = .display
        selectedIDs = []
        slashMenu = nil
        mentionProbe = nil
        focusedBlockID = nil
        focusedSelection = nil
    }

    /// Swipe gesture entry point. Always selects the originating block.
    func enterMultiSelect(with blockID: String) {
        mode = .multiSelect
        selectedIDs = [blockID]
        slashMenu = nil
        mentionProbe = nil
    }

    func toggleSelection(_ blockID: String) {
        guard case .multiSelect = mode else { return }
        if selectedIDs.contains(blockID) {
            selectedIDs.remove(blockID)
        } else {
            selectedIDs.insert(blockID)
        }
        if selectedIDs.isEmpty { enterDisplay() }
    }

    func reportRowFrame(blockID: String, frameInWindow: CGRect?) {
        if let frame = frameInWindow {
            rowFrames[blockID] = frame
        } else {
            rowFrames.removeValue(forKey: blockID)
        }
    }

    // MARK: - Slash command menu

    enum SlashOption: Equatable {
        case paragraph
        case heading(Int)
        case bulletList
        case orderedList
        case taskList
        case divider
    }

    func evaluateSlashTrigger(blockID: String, content: [InlineRun], caretInWindow: CGRect?) {
        guard let caret = caretInWindow else {
            if slashMenu?.blockID == blockID { slashMenu = nil }
            return
        }
        // Slash menu is active only for single-text-run blocks beginning
        // with "/" and containing no whitespace yet. This mirrors the rule
        // used by every block editor (Notion / Bear / Craft) — keeps the
        // detection cheap and lets us cancel as soon as the user types a
        // space or another block element.
        guard content.count == 1,
              case .text(let s, _) = content[0],
              s.hasPrefix("/"),
              !s.contains(" ")
        else {
            if slashMenu?.blockID == blockID { slashMenu = nil }
            return
        }
        let query = String(s.dropFirst())
        slashMenu = SlashMenuState(blockID: blockID, query: query, anchorInWindow: caret)
    }

    func dismissSlashMenu() { slashMenu = nil }

    func commitSlashOption(_ option: SlashOption) {
        guard let state = slashMenu,
              let idx = document.firstIndex(where: { $0.id == state.blockID })
        else { return }
        let blockID = state.blockID
        switch option {
        case .paragraph:
            document[idx] = .paragraph(id: blockID, content: [])
        case .heading(let level):
            document[idx] = .heading(id: blockID, level: level, content: [])
        case .bulletList:
            document[idx] = .listItem(id: blockID, kind: .bullet, level: 0, checked: false, content: [])
        case .orderedList:
            document[idx] = .listItem(id: blockID, kind: .ordered, level: 0, checked: false, content: [])
        case .taskList:
            document[idx] = .listItem(id: blockID, kind: .task, level: 0, checked: false, content: [])
        case .divider:
            document[idx] = .divider(id: blockID)
            let next = NoteBlock.paragraph(id: NoteBlockID.make(), content: [])
            document.insert(next, at: idx + 1)
            focusRequest = FocusRequest(blockID: next.id, offset: 0)
            slashMenu = nil
            scheduleSave()
            return
        }
        focusRequest = FocusRequest(blockID: blockID, offset: 0)
        slashMenu = nil
        scheduleSave()
    }

    // MARK: - Mention probe

    func evaluateMentionTrigger(blockID: String, content: [InlineRun], caretLocation: Int, caretInWindow: CGRect?) {
        guard let caret = caretInWindow else {
            mentionProbe = nil
            return
        }
        let plain = content.reduce(into: "") { $0 += $1.plainText }
        let scalars = Array(plain.utf16)
        guard caretLocation > 0, caretLocation <= scalars.count else {
            mentionProbe = nil
            return
        }
        // Walk backwards from caret to find the most recent "@" without an
        // intervening space.
        var atIdx: Int? = nil
        var i = caretLocation - 1
        while i >= 0 {
            let ch = scalars[i]
            if ch == 0x40 { atIdx = i; break }
            if ch == 0x20 || ch == 0x0A || ch == 0x09 { break }
            i -= 1
        }
        guard let start = atIdx else {
            mentionProbe = nil
            return
        }
        let queryUnits = Array(scalars[(start + 1)..<caretLocation])
        let query = String(utf16CodeUnits: queryUnits, count: queryUnits.count)
        mentionProbe = MentionProbe(blockID: blockID, query: query, anchorInWindow: caret)
    }

    func clearMentionProbe() { mentionProbe = nil }

    /// Replaces an active "@query" mention prefix with a place chip on the
    /// focused block. Used by the existing EditModeView mention picker.
    func acceptMention(placeID: String, name: String) {
        guard let probe = mentionProbe,
              let idx = document.firstIndex(where: { $0.id == probe.blockID })
        else { return }
        let block = document[idx]
        let plain = block.inlineContent.reduce(into: "") { $0 += $1.plainText }
        let scalars = Array(plain.utf16)
        // Find "@" start by scanning backward from the end. Conservative:
        // if there are several @-spans we take the latest non-spaced one.
        var atIdx: Int? = nil
        var i = scalars.count - 1
        while i >= 0 {
            let ch = scalars[i]
            if ch == 0x40 { atIdx = i; break }
            if ch == 0x20 || ch == 0x0A || ch == 0x09 { break }
            i -= 1
        }
        let start = atIdx ?? scalars.count
        let prefixUnits = Array(scalars[0..<start])
        let prefix = String(utf16CodeUnits: prefixUnits, count: prefixUnits.count)
        var runs: [InlineRun] = []
        if !prefix.isEmpty { runs.append(.text(prefix, attributes: [])) }
        runs.append(.placeRef(placeId: placeID, name: name))
        // Trailing space so the user can keep typing without manual nudging.
        runs.append(.text(" ", attributes: []))
        document[idx] = withContent(block, content: runs)
        mentionProbe = nil
        let caret = runs.reduce(0) { $0 + $1.plainText.utf16.count }
        focusRequest = FocusRequest(blockID: probe.blockID, offset: caret)
        scheduleSave()
    }

    // MARK: - Inline formatting commands (focused block)

    func toggleInlineAttribute(_ attribute: InlineAttributes) {
        guard let id = focusedBlockID,
              let selection = focusedSelection,
              selection.blockID == id,
              let idx = document.firstIndex(where: { $0.id == id })
        else { return }
        let block = document[idx]
        let runs = applyAttribute(
            attribute,
            to: block.inlineContent,
            range: NSRange(location: selection.location, length: selection.length)
        )
        document[idx] = withContent(block, content: runs)
        scheduleSave()
    }

    func transformFocusedBlock(_ transform: SlashOption) {
        guard let id = focusedBlockID,
              let idx = document.firstIndex(where: { $0.id == id })
        else { return }
        let content = document[idx].inlineContent
        switch transform {
        case .paragraph:
            document[idx] = .paragraph(id: id, content: content)
        case .heading(let level):
            document[idx] = .heading(id: id, level: level, content: content)
        case .bulletList:
            document[idx] = .listItem(id: id, kind: .bullet, level: 0, checked: false, content: content)
        case .orderedList:
            document[idx] = .listItem(id: id, kind: .ordered, level: 0, checked: false, content: content)
        case .taskList:
            document[idx] = .listItem(id: id, kind: .task, level: 0, checked: false, content: content)
        case .divider:
            document[idx] = .divider(id: id)
            let next = NoteBlock.paragraph(id: NoteBlockID.make(), content: [])
            document.insert(next, at: idx + 1)
            focusRequest = FocusRequest(blockID: next.id, offset: 0)
        }
        scheduleSave()
    }

    /// Inserts plain text at the caret of the focused block. Used by the
    /// toolbar's "@" button so that the normal mention-detection pipeline
    /// can light up without any extra plumbing.
    func insertTextAtCaret(_ text: String) {
        guard !text.isEmpty,
              let id = focusedBlockID,
              let selection = focusedSelection,
              selection.blockID == id,
              let idx = document.firstIndex(where: { $0.id == id })
        else { return }
        let block = document[idx]
        let runs = insertTextIntoRuns(block.inlineContent, text: text, at: selection.location)
        document[idx] = withContent(block, content: runs)
        let newCaret = selection.location + text.utf16.count
        focusRequest = FocusRequest(blockID: id, offset: newCaret)
        scheduleSave()
    }

    private func insertTextIntoRuns(_ runs: [InlineRun], text: String, at location: Int) -> [InlineRun] {
        var result: [InlineRun] = []
        var cursor = 0
        var inserted = false
        for run in runs {
            let len = run.plainText.utf16.count
            let runStart = cursor
            let runEnd = cursor + len
            cursor = runEnd
            if inserted {
                result.append(run)
                continue
            }
            if location <= runStart {
                result.append(.text(text, attributes: []))
                result.append(run)
                inserted = true
            } else if location < runEnd {
                if case .text(let s, let attrs) = run {
                    let units = Array(s.utf16)
                    let leftUnits = Array(units.prefix(location - runStart))
                    let rightUnits = Array(units.suffix(units.count - (location - runStart)))
                    let left = String(utf16CodeUnits: leftUnits, count: leftUnits.count)
                    let right = String(utf16CodeUnits: rightUnits, count: rightUnits.count)
                    if !left.isEmpty { result.append(.text(left, attributes: attrs)) }
                    result.append(.text(text, attributes: attrs))
                    if !right.isEmpty { result.append(.text(right, attributes: attrs)) }
                } else {
                    result.append(run)
                    result.append(.text(text, attributes: []))
                }
                inserted = true
            } else {
                result.append(run)
            }
        }
        if !inserted {
            result.append(.text(text, attributes: []))
        }
        return mergeAdjacentText(result)
    }

    func toggleTaskChecked(_ blockID: String) {
        guard let idx = document.firstIndex(where: { $0.id == blockID }) else { return }
        guard case .listItem(let id, let kind, let level, let checked, let content) = document[idx],
              kind == .task else { return }
        document[idx] = .listItem(id: id, kind: kind, level: level, checked: !checked, content: content)
        scheduleSave()
    }

    func insertImageBlock(url: String) {
        let imageID = NoteBlockID.make()
        let imageBlock = NoteBlock.image(id: imageID, url: url)
        if let id = focusedBlockID,
           let idx = document.firstIndex(where: { $0.id == id }) {
            document.insert(imageBlock, at: idx + 1)
            let trailing = NoteBlock.paragraph(id: NoteBlockID.make(), content: [])
            document.insert(trailing, at: idx + 2)
            focusRequest = FocusRequest(blockID: trailing.id, offset: 0)
        } else {
            document.append(imageBlock)
            let trailing = NoteBlock.paragraph(id: NoteBlockID.make(), content: [])
            document.append(trailing)
            focusRequest = FocusRequest(blockID: trailing.id, offset: 0)
        }
        scheduleSave()
    }

    func insertPlaceMention(placeID: String, name: String) {
        if mentionProbe != nil {
            acceptMention(placeID: placeID, name: name)
            return
        }
        guard let id = focusedBlockID,
              let idx = document.firstIndex(where: { $0.id == id })
        else { return }
        let block = document[idx]
        var runs = block.inlineContent
        runs.append(.placeRef(placeId: placeID, name: name))
        runs.append(.text(" ", attributes: []))
        document[idx] = withContent(block, content: runs)
        let caret = runs.reduce(0) { $0 + $1.plainText.utf16.count }
        focusRequest = FocusRequest(blockID: id, offset: caret)
        scheduleSave()
    }

    private func applyAttribute(
        _ attribute: InlineAttributes,
        to runs: [InlineRun],
        range: NSRange
    ) -> [InlineRun] {
        guard range.length > 0 else { return runs }
        var result: [InlineRun] = []
        var cursor = 0
        // Decide on or off based on whether the entire range already carries
        // the attribute (this mirrors how UIKit's `toggleBold` works).
        let shouldRemove = runRangeHasAttribute(runs, range: range, attribute: attribute)
        for run in runs {
            let len = run.plainText.utf16.count
            let runStart = cursor
            let runEnd = cursor + len
            let interStart = max(runStart, range.location)
            let interEnd = min(runEnd, range.location + range.length)
            cursor = runEnd
            guard interStart < interEnd else {
                result.append(run)
                continue
            }
            switch run {
            case .text(let s, let attrs):
                let units = Array(s.utf16)
                let leftUnits = Array(units.prefix(interStart - runStart))
                let midUnits = Array(units[(interStart - runStart)..<(interEnd - runStart)])
                let rightUnits = Array(units.suffix(units.count - (interEnd - runStart)))
                let left = String(utf16CodeUnits: leftUnits, count: leftUnits.count)
                let mid = String(utf16CodeUnits: midUnits, count: midUnits.count)
                let right = String(utf16CodeUnits: rightUnits, count: rightUnits.count)
                if !left.isEmpty { result.append(.text(left, attributes: attrs)) }
                var nextAttrs = attrs
                if shouldRemove { nextAttrs.remove(attribute) } else { nextAttrs.insert(attribute) }
                if !mid.isEmpty { result.append(.text(mid, attributes: nextAttrs)) }
                if !right.isEmpty { result.append(.text(right, attributes: attrs)) }
            case .placeRef:
                result.append(run)
            }
        }
        return mergeAdjacentText(result)
    }

    private func runRangeHasAttribute(
        _ runs: [InlineRun],
        range: NSRange,
        attribute: InlineAttributes
    ) -> Bool {
        var cursor = 0
        for run in runs {
            let len = run.plainText.utf16.count
            let runStart = cursor
            let runEnd = cursor + len
            cursor = runEnd
            let interStart = max(runStart, range.location)
            let interEnd = min(runEnd, range.location + range.length)
            guard interStart < interEnd else { continue }
            if case .text(_, let attrs) = run {
                if !attrs.contains(attribute) { return false }
            } else {
                return false
            }
        }
        return true
    }

    private func mergeAdjacentText(_ runs: [InlineRun]) -> [InlineRun] {
        var out: [InlineRun] = []
        for run in runs {
            if case .text(let s, let attrs) = run,
               case .text(let prevS, let prevAttrs) = out.last,
               prevAttrs == attrs {
                out[out.count - 1] = .text(prevS + s, attributes: attrs)
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: - Multi-select actions

    func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        document.removeAll { selectedIDs.contains($0.id) }
        if document.isEmpty {
            document = [.paragraph(id: NoteBlockID.make(), content: [])]
        }
        enterDisplay()
        scheduleSave()
    }

    /// Copy selected blocks to the system pasteboard as Markdown.
    func copySelectedToPasteboard() -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        let ordered = document.filter { selectedIDs.contains($0.id) }
        let md = NoteBlockMarkdown.serialize(ordered).trimmingCharacters(in: .whitespacesAndNewlines)
        if md.isEmpty { return false }
        UIPasteboard.general.string = md
        return true
    }

    // MARK: - Drag reorder
    //
    // Drag is allowed from `display` (single block) and `multiSelect` (whole
    // selection if the long-pressed block is selected; otherwise drops out
    // of multi-select and drags the single block).

    func beginDrag(blockID: String, at pointer: CGPoint) {
        let ids: [String]
        switch mode {
        case .multiSelect where selectedIDs.contains(blockID):
            ids = document.compactMap { selectedIDs.contains($0.id) ? $0.id : nil }
        case .multiSelect:
            // Dragging an unselected block exits multi-select first.
            enterDisplay()
            ids = [blockID]
        case .editing:
            // Drag from editing → drop the caret, drag the single block.
            enterDisplay()
            ids = [blockID]
        case .display:
            ids = [blockID]
        }
        guard !ids.isEmpty else { return }
        dragState = DragState(
            blockIDs: ids,
            pointerLocation: pointer,
            beforeBlockID: computeBeforeBlockID(pointerY: pointer.y, excluding: Set(ids))
        )
    }

    func updateDrag(pointer: CGPoint) {
        guard var state = dragState else { return }
        state.pointerLocation = pointer
        state.beforeBlockID = computeBeforeBlockID(
            pointerY: pointer.y,
            excluding: Set(state.blockIDs)
        )
        dragState = state
    }

    func endDrag(commit: Bool) {
        defer { dragState = nil }
        guard let state = dragState, commit else { return }
        let movingSet = Set(state.blockIDs)
        let movingBlocks = document.compactMap { movingSet.contains($0.id) ? $0 : nil }
        guard !movingBlocks.isEmpty else { return }
        var remaining = document.filter { !movingSet.contains($0.id) }
        let insertIndex: Int
        if let beforeID = state.beforeBlockID,
           let target = remaining.firstIndex(where: { $0.id == beforeID }) {
            insertIndex = target
        } else {
            insertIndex = remaining.count
        }
        remaining.insert(contentsOf: movingBlocks, at: insertIndex)
        document = remaining
        scheduleSave()
    }

    /// Picks the block whose top edge is the closest one *below* the pointer.
    /// `nil` means "drop at the very end of the document".
    private func computeBeforeBlockID(pointerY: CGFloat, excluding: Set<String>) -> String? {
        let candidates = document.compactMap { block -> (String, CGRect)? in
            guard !excluding.contains(block.id),
                  let frame = rowFrames[block.id] else { return nil }
            return (block.id, frame)
        }
        guard !candidates.isEmpty else { return nil }
        // Use the row's vertical midpoint as the threshold. If the pointer
        // is above the midpoint, the drop indicator goes above this row.
        for (id, frame) in candidates {
            if pointerY < frame.midY { return id }
        }
        return nil
    }

    // MARK: - Block mutations

    func setBlockContent(_ id: String, content: [InlineRun]) {
        guard let idx = index(of: id) else { return }
        document[idx] = withContent(document[idx], content: content)
        scheduleSave()
    }

    func splitBlock(_ id: String, at offset: Int) {
        guard let idx = index(of: id) else { return }
        let block = document[idx]
        let (before, after) = splitInlines(block.inlineContent, at: offset)
        document[idx] = withContent(block, content: before)
        let newID = NoteBlockID.make()
        let newBlock: NoteBlock = {
            switch block {
            case .heading:
                return .paragraph(id: newID, content: after)
            case .listItem(_, let kind, let level, _, _):
                if after.isEmpty, before.isEmpty {
                    // "Enter on empty list item" → exit the list as paragraph.
                    return .paragraph(id: newID, content: [])
                }
                return .listItem(id: newID, kind: kind, level: level, checked: false, content: after)
            default:
                return .paragraph(id: newID, content: after)
            }
        }()
        document.insert(newBlock, at: idx + 1)
        focusRequest = FocusRequest(blockID: newID, offset: 0)
        scheduleSave()
    }

    /// Handle Backspace at position 0: merge current block into the previous
    /// text-bearing block. If the previous block is a divider / image, just
    /// delete it instead.
    func mergeWithPrevious(_ id: String) {
        guard let idx = index(of: id), idx > 0 else { return }
        let curr = document[idx]
        let prev = document[idx - 1]
        switch prev {
        case .divider, .image:
            document.remove(at: idx - 1)
            focusRequest = FocusRequest(blockID: curr.id, offset: 0)
        default:
            let prevLen = inlineLength(prev.inlineContent)
            let merged = prev.inlineContent + curr.inlineContent
            document[idx - 1] = withContent(prev, content: merged)
            document.remove(at: idx)
            focusRequest = FocusRequest(blockID: prev.id, offset: prevLen)
        }
        scheduleSave()
    }

    func deleteBlock(_ id: String) {
        guard let idx = index(of: id) else { return }
        document.remove(at: idx)
        if document.isEmpty {
            let blank = NoteBlock.paragraph(id: NoteBlockID.make(), content: [])
            document.append(blank)
            focusRequest = FocusRequest(blockID: blank.id, offset: 0)
        }
        scheduleSave()
    }

    // MARK: - Helpers

    private func index(of id: String) -> Int? {
        document.firstIndex(where: { $0.id == id })
    }

    private func withContent(_ block: NoteBlock, content: [InlineRun]) -> NoteBlock {
        switch block {
        case .paragraph(let id, _):
            return .paragraph(id: id, content: content)
        case .heading(let id, let level, _):
            return .heading(id: id, level: level, content: content)
        case .listItem(let id, let kind, let level, let checked, _):
            return .listItem(id: id, kind: kind, level: level, checked: checked, content: content)
        case .divider, .image:
            return block
        }
    }

    private func inlineLength(_ runs: [InlineRun]) -> Int {
        runs.reduce(0) { $0 + $1.plainText.utf16.count }
    }

    private func splitInlines(_ runs: [InlineRun], at offset: Int) -> ([InlineRun], [InlineRun]) {
        var before: [InlineRun] = []
        var after: [InlineRun] = []
        var cursor = 0
        for run in runs {
            let len = run.plainText.utf16.count
            if cursor + len <= offset {
                before.append(run)
                cursor += len
                continue
            }
            if cursor >= offset {
                after.append(run)
                cursor += len
                continue
            }
            let local = offset - cursor
            switch run {
            case .text(let s, let attrs):
                let units = Array(s.utf16)
                let leftUnits = Array(units.prefix(local))
                let rightUnits = Array(units.dropFirst(local))
                let left = String(utf16CodeUnits: leftUnits, count: leftUnits.count)
                let right = String(utf16CodeUnits: rightUnits, count: rightUnits.count)
                if !left.isEmpty { before.append(.text(left, attributes: attrs)) }
                if !right.isEmpty { after.append(.text(right, attributes: attrs)) }
            case .placeRef:
                // Place chips are atomic — push to whichever side the split fell.
                if local >= len / 2 { before.append(run) } else { after.append(run) }
            }
            cursor += len
        }
        return (before, after)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        hasUnsavedChanges = true
        persistTask?.cancel()
        let snapshot = document
        let id = noteID
        let store = store
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let (markdown, blocks) = NoteDocumentBridge.materialize(snapshot)
            if let blocks {
                store?.updateBlocks(noteID: id, blocks: blocks, markdown: markdown)
            } else {
                store?.updateMarkdown(noteID: id, markdown: markdown)
            }
            self?.hasUnsavedChanges = false
        }
    }

    func flushPendingSave() {
        guard hasUnsavedChanges else { return }
        persistTask?.cancel()
        let (markdown, blocks) = NoteDocumentBridge.materialize(document)
        if let blocks {
            store?.updateBlocks(noteID: noteID, blocks: blocks, markdown: markdown)
        } else {
            store?.updateMarkdown(noteID: noteID, markdown: markdown)
        }
        hasUnsavedChanges = false
    }
}
