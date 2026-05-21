import Foundation

enum BlocksFeatureFlag {
    static var useBlocksAsSource: Bool {
        // Phase 2 default: ON. Set "phase2-blocks-disabled" in UserDefaults to force rollback.
        !UserDefaults.standard.bool(forKey: "phase2-blocks-disabled")
    }
}

enum BlocksService {
    struct Section: Hashable {
        var title: String
        var index: Int
        var placeIDs: [String]
    }

    static func decode(_ data: Data?) -> [Any]? {
        guard let data, !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [Any]
        else { return nil }
        return array
    }

    /// Walks the Tiptap tree and returns placeIds in document order (deduped).
    static func extractPlaceIDs(blocks: [Any]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        walk(blocks) { node in
            guard let dict = node as? [String: Any] else { return }
            if let type = dict["type"] as? String, type == "placeRef",
               let placeId = placeID(in: dict),
               !placeId.isEmpty,
               !seen.contains(placeId) {
                seen.insert(placeId)
                result.append(placeId)
            }
        }
        return result
    }

    static func orderedPlaces(note: Note) -> [Place]? {
        guard let blocks = decode(note.blocks) else { return nil }
        let ids = extractPlaceIDs(blocks: blocks)
        var seen: Set<String> = []
        return ids.compactMap { placeId in
            guard !seen.contains(placeId) else { return nil }
            seen.insert(placeId)
            return note.places.first(where: { $0.id == placeId || $0.placeId == placeId })
        }
    }

    /// Returns sections split by H1 headings, with the placeIds found inside each.
    static func sections(blocks: [Any]) -> [Section] {
        var sections: [Section] = []
        var currentTitle: String?
        var currentIDs: [String] = []
        var idx = 0

        func flush() {
            guard let title = currentTitle else { return }
            sections.append(Section(title: title, index: idx, placeIDs: currentIDs))
            idx += 1
            currentIDs = []
        }

        for block in blocks {
            guard let dict = block as? [String: Any],
                  let type = dict["type"] as? String
            else { continue }
            if type == "heading",
               headingLevel(in: dict) == 1 {
                flush()
                currentTitle = inlineText(dict["content"])
            } else if currentTitle != nil {
                walk([block]) { node in
                    guard let nd = node as? [String: Any] else { return }
                    if let t = nd["type"] as? String, t == "placeRef",
                       let pid = placeID(in: nd), !pid.isEmpty {
                        currentIDs.append(pid)
                    }
                }
            }
        }
        flush()
        return sections
    }

    /// Extract plain text in the same flow order; used to derive per-place context notes.
    /// Returns map placeId -> note text (paragraphs between this placeRef and next placeRef or H1).
    static func extractPlaceNotes(blocks: [Any]) -> [String: String] {
        // Flatten document into events: heading/H1, placeRef(id), text(string)
        enum Event { case heading; case placeRef(String); case text(String) }
        var events: [Event] = []

        func handleBlock(_ block: [String: Any]) {
            guard let type = block["type"] as? String else { return }
            if type == "heading",
               headingLevel(in: block) == 1 {
                events.append(.heading)
                return
            }
            if let content = block["content"] as? [Any] {
                for inline in content {
                    guard let nd = inline as? [String: Any] else { continue }
                    if let t = nd["type"] as? String {
                        if t == "placeRef", let pid = placeID(in: nd), !pid.isEmpty {
                            events.append(.placeRef(pid))
                        } else if t == "text", let text = nd["text"] as? String {
                            events.append(.text(text))
                        }
                    }
                }
                events.append(.text("\n"))
            }
            if let children = block["children"] as? [Any] {
                for c in children {
                    if let cd = c as? [String: Any] { handleBlock(cd) }
                }
            }
        }

        for block in blocks {
            if let bd = block as? [String: Any] { handleBlock(bd) }
        }

        var notes: [String: String] = [:]
        var currentID: String?
        var buffer = ""
        func flush() {
            guard let id = currentID else { return }
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { notes[id] = trimmed }
            buffer = ""
        }

        for ev in events {
            switch ev {
            case .heading:
                flush()
                currentID = nil
            case .placeRef(let id):
                flush()
                currentID = id
            case .text(let s):
                if currentID != nil { buffer += s }
            }
        }
        flush()
        return notes
    }

    /// Walk every block / nested child / inline content node recursively.
    private static func walk(_ nodes: [Any], visit: (Any) -> Void) {
        for node in nodes {
            visit(node)
            guard let dict = node as? [String: Any] else { continue }
            if let content = dict["content"] as? [Any] {
                walk(content, visit: visit)
            }
            if let children = dict["children"] as? [Any] {
                walk(children, visit: visit)
            }
        }
    }

    private static func inlineText(_ content: Any?) -> String {
        guard let arr = content as? [Any] else { return "" }
        var result = ""
        for item in arr {
            guard let dict = item as? [String: Any] else { continue }
            if let t = dict["type"] as? String, t == "text", let text = dict["text"] as? String {
                result += text
            } else if let child = dict["content"] as? [Any] {
                result += inlineText(child)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingLevel(in dict: [String: Any]) -> Int? {
        if let attrs = dict["attrs"] as? [String: Any], let level = attrs["level"] as? Int {
            return level
        }
        if let props = dict["props"] as? [String: Any], let level = props["level"] as? Int {
            return level
        }
        return nil
    }

    private static func placeID(in dict: [String: Any]) -> String? {
        if let attrs = dict["attrs"] as? [String: Any], let id = attrs["placeId"] as? String {
            return id
        }
        if let props = dict["props"] as? [String: Any], let id = props["placeId"] as? String {
            return id
        }
        return nil
    }

    /// Reorder top-level blocks so their first contained `placeRef` matches `newOrder`.
    /// Blocks that contain no placeRef stay in their original positions (used as anchors).
    /// Useful when the user reorders waypoints on the map and we need to mirror that
    /// change inside the editor's block tree.
    static func reorderingPlaces(
        _ blocks: Data?,
        newOrder: [String],
        scope: ScopePredicate = .all
    ) -> Data? {
        guard let blocks,
              let json = try? JSONSerialization.jsonObject(with: blocks),
              let arr = json as? [Any]
        else { return blocks }

        // Discover the primary placeId for each top-level block.
        var primaryByIndex: [Int: String] = [:]
        for (idx, node) in arr.enumerated() {
            guard let dict = node as? [String: Any] else { continue }
            var firstID: String?
            walk([dict]) { inner in
                guard firstID == nil,
                      let nd = inner as? [String: Any],
                      let t = nd["type"] as? String, t == "placeRef",
                      let pid = placeID(in: nd), !pid.isEmpty
                else { return }
                firstID = pid
            }
            if let firstID { primaryByIndex[idx] = firstID }
        }

        // Decide which top-level blocks are affected by the reorder scope.
        let scopeIndices = scope.indices(in: arr)
        let affectedIndices = scopeIndices.filter { primaryByIndex[$0] != nil }
        guard !affectedIndices.isEmpty else { return blocks }

        // Build a sort key: each affected block's new rank = position of its
        // primaryID in `newOrder`. Unknown IDs sink to the end while preserving
        // their relative order.
        let rank = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($1, $0) })
        let sorted = affectedIndices.sorted { a, b in
            let ra = rank[primaryByIndex[a]!] ?? Int.max
            let rb = rank[primaryByIndex[b]!] ?? Int.max
            if ra != rb { return ra < rb }
            return a < b
        }

        // Splice the sorted blocks back into their original positions.
        var newArr = arr
        for (slot, originalIdx) in zip(affectedIndices, sorted) {
            newArr[slot] = arr[originalIdx]
        }
        return try? JSONSerialization.data(withJSONObject: newArr)
    }

    enum ScopePredicate {
        case all
        case section(title: String)

        func indices(in arr: [Any]) -> [Int] {
            switch self {
            case .all:
                return Array(arr.indices)
            case .section(let title):
                var out: [Int] = []
                var inside = false
                for (idx, node) in arr.enumerated() {
                    guard let dict = node as? [String: Any] else {
                        if inside { out.append(idx) }
                        continue
                    }
                    if let t = dict["type"] as? String, t == "heading",
                       headingLevel(in: dict) == 1 {
                        let headingTitle = inlineText(dict["content"])
                        if headingTitle == title {
                            inside = true
                            continue
                        } else if inside {
                            break
                        }
                    } else if inside {
                        out.append(idx)
                    }
                }
                return out
            }
        }
    }

    /// Strip placeRef nodes whose props.placeId matches `placeID`. Returns mutated tree as JSON Data.
    static func removingPlaceRef(_ blocks: Data?, placeID: String) -> Data? {
        guard let blocks, let json = try? JSONSerialization.jsonObject(with: blocks),
              var arr = json as? [Any]
        else { return blocks }

        func clean(_ nodes: [Any]) -> [Any] {
            var out: [Any] = []
            for node in nodes {
                guard var dict = node as? [String: Any] else { out.append(node); continue }
                if let t = dict["type"] as? String, t == "placeRef",
                   Self.placeID(in: dict) == placeID {
                    continue
                }
                if let content = dict["content"] as? [Any] {
                    dict["content"] = clean(content)
                }
                if let children = dict["children"] as? [Any] {
                    dict["children"] = clean(children)
                }
                out.append(dict)
            }
            return out
        }

        arr = clean(arr)
        return try? JSONSerialization.data(withJSONObject: arr)
    }
}
