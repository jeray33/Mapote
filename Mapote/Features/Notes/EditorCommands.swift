import Foundation

enum EditorCommandKind: Equatable {
    case insertText(String)
    case toggleBold
    case heading(Int)
    case bulletList
    case orderedList
    case taskList
    case divider
    case undo
    case redo
}

struct EditorInsertCommand: Identifiable, Equatable {
    let id = UUID()
    var kind: EditorCommandKind
}

