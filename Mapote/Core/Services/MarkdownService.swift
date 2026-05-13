import Foundation

enum MarkdownService {
    static let placeRegex = try! NSRegularExpression(pattern: #"::place\[([^\]]*)\]\{#([^}]+)\}"#)

    struct Section: Identifiable, Hashable {
        var id: String { title + "-" + String(index) }
        var title: String
        var index: Int
        var placeIDs: [String]
    }

    static func orderedPlaces(note: Note) -> [Place] {
        if BlocksFeatureFlag.useBlocksAsSource,
           let fromBlocks = BlocksService.orderedPlaces(note: note),
           !fromBlocks.isEmpty {
            return fromBlocks
        }
        var seen: Set<String> = []
        let ids = extractPlaceIDs(from: note.markdown)
        return ids.compactMap { placeId in
            guard !seen.contains(placeId) else { return nil }
            seen.insert(placeId)
            return note.places.first(where: { $0.id == placeId || $0.placeId == placeId })
        }
    }

    static func extractPlaceIDs(from markdown: String) -> [String] {
        let ns = markdown as NSString
        let matches = placeRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap {
            guard $0.numberOfRanges > 2 else { return nil }
            return ns.substring(with: $0.range(at: 2))
        }
    }

    static func getPlacesBySection(note: Note) -> [Section] {
        if BlocksFeatureFlag.useBlocksAsSource,
           let blocks = BlocksService.decode(note.blocks) {
            let raw = BlocksService.sections(blocks: blocks)
            if !raw.isEmpty {
                return raw.map { Section(title: $0.title, index: $0.index, placeIDs: $0.placeIDs) }
            }
        }
        return getPlacesBySection(markdown: note.markdown)
    }

    static func extractPlaceNotes(note: Note) -> [String: String] {
        if BlocksFeatureFlag.useBlocksAsSource,
           let blocks = BlocksService.decode(note.blocks) {
            let raw = BlocksService.extractPlaceNotes(blocks: blocks)
            if !raw.isEmpty { return raw }
        }
        return extractPlaceNotes(markdown: note.markdown)
    }

    static func getPlacesBySection(markdown: String) -> [Section] {
        let lines = markdown.components(separatedBy: .newlines)
        var sections: [Section] = []
        var currentTitle: String?
        var buffer: [String] = []
        var idx = 0

        func flush() {
            guard let currentTitle else { return }
            let ids = extractPlaceIDs(from: buffer.joined(separator: "\n"))
            sections.append(Section(title: currentTitle, index: idx, placeIDs: ids))
            idx += 1
        }

        for line in lines {
            if line.hasPrefix("# ") {
                flush()
                currentTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = []
            } else if currentTitle != nil {
                buffer.append(line)
            }
        }
        flush()
        return sections
    }

    static func extractPlaceNotes(markdown: String) -> [String: String] {
        let ns = markdown as NSString
        let matches = placeRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [:] }

        var notes: [String: String] = [:]

        for idx in 0..<matches.count {
            let current = matches[idx]
            let placeId = ns.substring(with: current.range(at: 2))
            let start = current.range.location + current.range.length
            let end: Int

            if idx + 1 < matches.count {
                end = matches[idx + 1].range.location
            } else {
                end = ns.length
            }
            guard end >= start else { continue }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let cleaned = raw
                .components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("# ") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            notes[placeId] = cleaned
        }
        return notes
    }

    static func stripPlaceTags(_ markdown: String) -> String {
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        return placeRegex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "")
    }

    static func replaceFirstOccurrence(in markdown: String, target: String, replacement: String) -> String {
        guard let range = markdown.range(of: target) else { return markdown }
        var result = markdown
        result.replaceSubrange(range, with: replacement)
        return result
    }
}

