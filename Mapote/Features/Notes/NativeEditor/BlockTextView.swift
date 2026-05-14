import SwiftUI
import UIKit

// A UITextView per block. With `isScrollEnabled = false` the text view sizes
// itself to its content and behaves like a leaf inside SwiftUI layout.
//
// Mode handling
// -------------
// • `.editing` — fully editable, owns the caret, becomes first responder.
// • `.display` / `.multiSelect` — no caret, no selection, no keyboard. We
//   still need to capture taps so we can transition into editing (display)
//   or toggle selection (multi-select), so a small tap recognizer lives on
//   the text view at all times.
struct BlockTextView: UIViewRepresentable {
    let blockID: String
    let content: [InlineRun]
    let style: BlockAttributedString.Style
    let isEditable: Bool
    let mode: NoteBlockController.Mode
    let pendingFocus: NoteBlockController.FocusRequest?
    let controller: NoteBlockController

    func makeUIView(context: Context) -> UITextView {
        let tv = BlockUITextView()
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.autocorrectionType = .default
        tv.spellCheckingType = .default
        tv.adjustsFontForContentSizeCategory = true
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.onDeleteAtStart = { [weak controller] id in
            controller?.mergeWithPrevious(id)
        }

        // Tap recognizer is the only way back into editing from display/multi
        // select. We compute the character offset at the tap point and ask
        // the controller to enter editing. The recognizer also handles the
        // multi-select tap-to-toggle case.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        context.coordinator.textView = tv
        context.coordinator.parent = self
        applyContent(to: tv, context: context, force: true)
        applyMode(to: tv, context: context)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if let block = tv as? BlockUITextView {
            block.blockID = blockID
        }
        applyContent(to: tv, context: context, force: false)
        applyMode(to: tv, context: context)
        applyFocusIfNeeded(tv, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Private helpers

    private func applyContent(to tv: UITextView, context: Context, force: Bool) {
        if context.coordinator.isApplyingUserChange { return }
        let desired = BlockAttributedString.make(content, style: style)
        if !force, attributedStringsEqual(tv.attributedText, desired) { return }
        let selected = tv.selectedRange
        tv.attributedText = desired
        tv.typingAttributes = BlockAttributedString.typingAttributes(for: style)
        let maxLoc = max(0, desired.length)
        let safeLoc = min(selected.location, maxLoc)
        let safeLen = min(selected.length, maxLoc - safeLoc)
        tv.selectedRange = NSRange(location: safeLoc, length: safeLen)
    }

    /// Applies the current mode to the text view. In every non-editing mode
    /// we make it completely inert (no caret, no text selection, no
    /// keyboard) — taps go through the recognizer we attached in
    /// `makeUIView`.
    private func applyMode(to tv: UITextView, context: Context) {
        let editingThisBlock: Bool = {
            if case .editing(let id) = mode { return id == blockID }
            return false
        }()
        if editingThisBlock && isEditable {
            tv.isEditable = true
            tv.isSelectable = true
        } else {
            if tv.isFirstResponder { tv.resignFirstResponder() }
            tv.isEditable = false
            tv.isSelectable = false
        }
    }

    private func applyFocusIfNeeded(_ tv: UITextView, context: Context) {
        guard let req = pendingFocus, req.blockID == blockID else { return }
        guard case .editing(let id) = mode, id == blockID else { return }
        let target = req.offset ?? tv.text.utf16.count
        let length = tv.attributedText.length
        let pos = min(max(0, target), length)
        DispatchQueue.main.async {
            tv.isEditable = true
            tv.isSelectable = true
            if !tv.isFirstResponder {
                tv.becomeFirstResponder()
            }
            tv.selectedRange = NSRange(location: pos, length: 0)
            controller.focusRequest = nil
        }
    }

    private func attributedStringsEqual(
        _ a: NSAttributedString,
        _ b: NSAttributedString
    ) -> Bool {
        guard a.length == b.length, a.string == b.string else { return false }
        return a.isEqual(to: b)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?
        weak var tapRecognizer: UITapGestureRecognizer?
        var parent: BlockTextView?
        var isApplyingUserChange = false

        // MARK: Tap to enter editing / toggle selection

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let parent, let tv = textView else { return }
            switch parent.controller.mode {
            case .editing(let id) where id == parent.blockID:
                // Already editing this block — let UITextView handle caret
                // placement on its own. We shouldn't get here in practice
                // because the recognizer is disabled in editing, but being
                // defensive is cheap.
                return
            case .multiSelect:
                parent.controller.toggleSelection(parent.blockID)
            default:
                let location = recognizer.location(in: tv)
                let offset = characterOffset(in: tv, at: location)
                parent.controller.enterEditing(blockID: parent.blockID, offset: offset)
            }
        }

        /// Translates a tap point into a UTF-16 character offset.
        private func characterOffset(in tv: UITextView, at point: CGPoint) -> Int {
            guard let position = tv.closestPosition(to: point) else {
                return tv.attributedText.length
            }
            return tv.offset(from: tv.beginningOfDocument, to: position)
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // Only intercept taps when we want to short-circuit UIKit
            // (i.e. when not currently editing this block). In editing mode
            // the text view's own tap → caret-placement logic should win.
            guard let parent else { return false }
            if case .editing(let id) = parent.controller.mode, id == parent.blockID {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Let our tap coexist with the parent ScrollView's pan and the
            // SwiftUI gestures attached to the row container.
            true
        }

        // MARK: UITextViewDelegate

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard let parent else { return true }
            // Enter → split into a new block at the cursor.
            if text == "\n" {
                isApplyingUserChange = true
                defer { isApplyingUserChange = false }
                let inlines = BlockAttributedString.parse(textView.attributedText)
                parent.controller.setBlockContent(parent.blockID, content: inlines)
                parent.controller.splitBlock(parent.blockID, at: range.location)
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let parent else { return }
            isApplyingUserChange = true
            defer { isApplyingUserChange = false }
            let inlines = BlockAttributedString.parse(textView.attributedText)
            parent.controller.setBlockContent(parent.blockID, content: inlines)
            updateProbes(textView: textView, inlines: inlines)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let parent else { return }
            parent.controller.focusedBlockID = parent.blockID
            // Make sure the controller's FSM knows we're editing this block.
            if case .editing(let id) = parent.controller.mode, id == parent.blockID {
                // already in sync
            } else {
                parent.controller.mode = .editing(blockID: parent.blockID)
                parent.controller.selectedIDs = []
            }
            updateSelection(textView: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard let parent else { return }
            if parent.controller.focusedBlockID == parent.blockID {
                parent.controller.focusedBlockID = nil
                parent.controller.focusedSelection = nil
            }
            parent.controller.dismissSlashMenu()
            parent.controller.clearMentionProbe()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateSelection(textView: textView)
            let inlines = BlockAttributedString.parse(textView.attributedText)
            updateProbes(textView: textView, inlines: inlines)
        }

        private func updateSelection(textView: UITextView) {
            guard let parent else { return }
            let range = textView.selectedRange
            parent.controller.focusedSelection = NoteBlockController.SelectionRange(
                blockID: parent.blockID,
                location: range.location,
                length: range.length
            )
        }

        private func updateProbes(textView: UITextView, inlines: [InlineRun]) {
            guard let parent else { return }
            let caretRect = caretRectInWindow(textView)
            parent.controller.evaluateSlashTrigger(
                blockID: parent.blockID,
                content: inlines,
                caretInWindow: caretRect
            )
            parent.controller.evaluateMentionTrigger(
                blockID: parent.blockID,
                content: inlines,
                caretLocation: textView.selectedRange.location,
                caretInWindow: caretRect
            )
        }

        private func caretRectInWindow(_ tv: UITextView) -> CGRect? {
            guard let range = tv.selectedTextRange else { return nil }
            let rect = tv.caretRect(for: range.start)
            guard !rect.isInfinite, !rect.isNull else { return nil }
            if let window = tv.window {
                return tv.convert(rect, to: window)
            }
            return nil
        }
    }
}

// Custom subclass to intercept the empty-range backspace that UITextView
// otherwise swallows (`shouldChangeTextIn` is not called for the leading
// backspace when the range is {0,0}).
final class BlockUITextView: UITextView {
    var blockID: String = ""
    var onDeleteAtStart: ((String) -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0 {
            onDeleteAtStart?(blockID)
            return
        }
        super.deleteBackward()
    }
}
