import Foundation

// Lightweight JSON codec for NoteBlock. We don't reuse Codable synthesis on
// the enum directly because the shape would be unstable across renames; this
// hand-written schema is what gets persisted into `Note.blocks` going forward
// and what we cross-check against the BlockNote legacy JSON during migration.

enum NoteBlockCodec {
    nonisolated static let schemaVersion = 1

    // MARK: Encode

    nonisolated static func encode(_ document: NoteDocument) -> Data? {
        let payload: [String: Any] = [
            "v": schemaVersion,
            "blocks": document.map(encodeBlock),
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: Decode

    nonisolated static func decode(_ data: Data?) -> NoteDocument? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["v"] as? Int,
              version == schemaVersion,
              let rawBlocks = root["blocks"] as? [[String: Any]]
        else { return nil }
        return rawBlocks.compactMap(decodeBlock)
    }

    // MARK: Block encoding

    nonisolated private static func encodeBlock(_ block: NoteBlock) -> [String: Any] {
        switch block {
        case .paragraph(let id, let content):
            return [
                "type": "paragraph",
                "id": id,
                "content": encodeInlines(content),
            ]
        case .heading(let id, let level, let content):
            return [
                "type": "heading",
                "id": id,
                "level": level,
                "content": encodeInlines(content),
            ]
        case .listItem(let id, let kind, let level, let checked, let content):
            return [
                "type": "listItem",
                "id": id,
                "kind": kind.rawValue,
                "level": level,
                "checked": checked,
                "content": encodeInlines(content),
            ]
        case .divider(let id):
            return ["type": "divider", "id": id]
        case .image(let id, let url):
            return ["type": "image", "id": id, "url": url]
        }
    }

    nonisolated private static func decodeBlock(_ dict: [String: Any]) -> NoteBlock? {
        guard let type = dict["type"] as? String else { return nil }
        let id = (dict["id"] as? String) ?? NoteBlockID.make()
        switch type {
        case "paragraph":
            return .paragraph(id: id, content: decodeInlines(dict["content"]))
        case "heading":
            let level = (dict["level"] as? Int).map { max(1, min(3, $0)) } ?? 1
            return .heading(id: id, level: level, content: decodeInlines(dict["content"]))
        case "listItem":
            let kind = BlockListKind(rawValue: (dict["kind"] as? String) ?? "bullet") ?? .bullet
            let level = dict["level"] as? Int ?? 0
            let checked = dict["checked"] as? Bool ?? false
            return .listItem(id: id, kind: kind, level: level, checked: checked, content: decodeInlines(dict["content"]))
        case "divider":
            return .divider(id: id)
        case "image":
            guard let url = dict["url"] as? String else { return nil }
            return .image(id: id, url: url)
        default:
            return nil
        }
    }

    // MARK: Inline encoding

    nonisolated private static func encodeInlines(_ runs: [InlineRun]) -> [[String: Any]] {
        runs.map { run in
            switch run {
            case .text(let s, let attrs):
                var dict: [String: Any] = ["type": "text", "text": s]
                if !attrs.isEmpty {
                    dict["attrs"] = encodeAttrs(attrs)
                }
                return dict
            case .placeRef(let placeId, let name):
                return ["type": "placeRef", "placeId": placeId, "name": name]
            }
        }
    }

    nonisolated private static func decodeInlines(_ raw: Any?) -> [InlineRun] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { decodeInline($0) }
    }

    nonisolated private static func decodeInline(_ dict: [String: Any]) -> InlineRun? {
        guard let type = dict["type"] as? String else { return nil }
        switch type {
        case "text":
            let s = (dict["text"] as? String) ?? ""
            let attrs = decodeAttrs(dict["attrs"])
            return .text(s, attributes: attrs)
        case "placeRef":
            guard let placeId = dict["placeId"] as? String else { return nil }
            let name = (dict["name"] as? String) ?? ""
            return .placeRef(placeId: placeId, name: name)
        default:
            return nil
        }
    }

    nonisolated private static func encodeAttrs(_ attrs: InlineAttributes) -> [String] {
        var out: [String] = []
        if attrs.contains(.bold) { out.append("bold") }
        if attrs.contains(.italic) { out.append("italic") }
        if attrs.contains(.code) { out.append("code") }
        return out
    }

    nonisolated private static func decodeAttrs(_ raw: Any?) -> InlineAttributes {
        guard let arr = raw as? [String] else { return [] }
        var attrs: InlineAttributes = []
        for name in arr {
            switch name {
            case "bold": attrs.insert(.bold)
            case "italic": attrs.insert(.italic)
            case "code": attrs.insert(.code)
            default: break
            }
        }
        return attrs
    }
}
