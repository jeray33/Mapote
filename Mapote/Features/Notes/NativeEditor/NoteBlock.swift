import Foundation

// Native block-based note model.
//
// Design notes
// ------------
// • Flat list of blocks (no nesting). List items are siblings carrying an
//   indentation level — same as Notion / Bear / Apple Notes. This keeps
//   selection, drag-reorder and per-block editing trivial.
// • Each block has a stable `id` so selection, drag and animation can refer
//   to a single block across renders.
// • Inline content is an array of `InlineRun` so a paragraph can mix plain
//   text, formatted runs and place chips on the same line.
// • Markdown remains the canonical persistence format for compatibility with
//   the existing MapMode / ListMode / AI services. Blocks are an
//   in-memory editing representation that round-trips through Markdown.

struct InlineAttributes: OptionSet, Hashable, Codable {
    let rawValue: Int
    static let bold = InlineAttributes(rawValue: 1 << 0)
    static let italic = InlineAttributes(rawValue: 1 << 1)
    static let code = InlineAttributes(rawValue: 1 << 2)
}

enum InlineRun: Hashable {
    case text(String, attributes: InlineAttributes)
    case placeRef(placeId: String, name: String)

    var plainText: String {
        switch self {
        case .text(let s, _): return s
        case .placeRef(_, let name): return name
        }
    }
}

enum BlockListKind: String, Codable, Hashable {
    case bullet
    case ordered
    case task
}

enum NoteBlock: Hashable, Identifiable {
    case paragraph(id: String, content: [InlineRun])
    case heading(id: String, level: Int, content: [InlineRun])
    case listItem(id: String, kind: BlockListKind, level: Int, checked: Bool, content: [InlineRun])
    case divider(id: String)
    case image(id: String, url: String)

    var id: String {
        switch self {
        case .paragraph(let id, _),
             .heading(let id, _, _),
             .listItem(let id, _, _, _, _),
             .divider(let id),
             .image(let id, _):
            return id
        }
    }

    var inlineContent: [InlineRun] {
        switch self {
        case .paragraph(_, let c),
             .heading(_, _, let c),
             .listItem(_, _, _, _, let c):
            return c
        case .divider, .image:
            return []
        }
    }

    var plainText: String {
        inlineContent.map(\.plainText).joined()
    }
}

typealias NoteDocument = [NoteBlock]

enum NoteBlockID {
    static func make() -> String {
        UUID().uuidString
    }
}
