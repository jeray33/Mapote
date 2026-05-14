import Foundation

// Markdown <-> NoteDocument round-trip.
//
// The Markdown dialect mirrors what the legacy TiptapEditor / BlockNote was
// already producing, so existing notes load unchanged and downstream services
// (MapMode, ListMode, AI extraction) keep working.
//
// Supported syntax
// ----------------
//   # H1 / ## H2 / ### H3
//   - bullet item                        (level by leading two-space indent)
//   1. ordered item
//   - [ ] task / - [x] task
//   ---                                  divider (also `***` / `___`)
//   ![alt](url)                          image-only paragraph
//   ::place[Name]{#placeId}              inline place chip
//   **bold**, *italic*, `code`
//   Plain paragraphs separated by blank lines.

enum NoteBlockMarkdown {

    // MARK: - Markdown → NoteDocument

    static func parse(_ markdown: String) -> NoteDocument {
        var blocks: NoteDocument = []
        let lines = markdown.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let raw = lines[idx]
            let trimmedLeading = raw.drop(while: { $0 == " " || $0 == "\t" })
            let indent = raw.count - trimmedLeading.count
            let level = max(0, min(4, indent / 2))
            let line = String(trimmedLeading)

            if line.isEmpty {
                idx += 1
                continue
            }

            // Heading
            if let heading = parseHeading(line: line) {
                blocks.append(heading)
                idx += 1
                continue
            }

            // Horizontal rule
            if isDivider(line) {
                blocks.append(.divider(id: NoteBlockID.make()))
                idx += 1
                continue
            }

            // Image-only line
            if let image = parseImageOnlyLine(line) {
                blocks.append(image)
                idx += 1
                continue
            }

            // Task list (- [ ] / - [x] / * [ ])
            if let task = parseTaskItem(line: line, level: level) {
                blocks.append(task)
                idx += 1
                continue
            }

            // Bullet list (-, *, +)
            if let bullet = parseBulletItem(line: line, level: level) {
                blocks.append(bullet)
                idx += 1
                continue
            }

            // Ordered list (1. / 2. / ...)
            if let ordered = parseOrderedItem(line: line, level: level) {
                blocks.append(ordered)
                idx += 1
                continue
            }

            // Paragraph: collect contiguous non-empty / non-block-prefix lines.
            var paragraphLines: [String] = [line]
            var lookahead = idx + 1
            while lookahead < lines.count {
                let next = lines[lookahead]
                let nextTrim = next.drop(while: { $0 == " " || $0 == "\t" })
                if nextTrim.isEmpty { break }
                if isBlockBoundary(String(nextTrim)) { break }
                paragraphLines.append(String(nextTrim))
                lookahead += 1
            }
            let combined = paragraphLines.joined(separator: "\n")
            blocks.append(.paragraph(id: NoteBlockID.make(), content: parseInlines(combined)))
            idx = lookahead
        }
        return blocks
    }

    // MARK: - NoteDocument → Markdown

    static func serialize(_ document: NoteDocument) -> String {
        var out: [String] = []
        for (i, block) in document.enumerated() {
            let line: String
            switch block {
            case .paragraph(_, let content):
                line = serializeInlines(content)
            case .heading(_, let level, let content):
                let hashes = String(repeating: "#", count: max(1, min(3, level)))
                line = "\(hashes) \(serializeInlines(content))"
            case .listItem(_, let kind, let level, let checked, let content):
                let pad = String(repeating: "  ", count: max(0, level))
                let bullet: String
                switch kind {
                case .bullet: bullet = "-"
                case .ordered: bullet = "1."
                case .task: bullet = checked ? "- [x]" : "- [ ]"
                }
                line = "\(pad)\(bullet) \(serializeInlines(content))"
            case .divider:
                line = "---"
            case .image(_, let url):
                line = "![](\(url))"
            }
            out.append(line)
            // Blank line after paragraph / heading / divider / image to keep
            // the output readable. List items stay packed.
            let isList: Bool
            if case .listItem = block { isList = true } else { isList = false }
            let nextIsList: Bool = {
                guard i + 1 < document.count else { return false }
                if case .listItem = document[i + 1] { return true }
                return false
            }()
            if !(isList && nextIsList) {
                out.append("")
            }
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Line classifiers

    private static func parseHeading(line: String) -> NoteBlock? {
        for level in (1...3).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                let body = String(line.dropFirst(prefix.count))
                return .heading(id: NoteBlockID.make(), level: level, content: parseInlines(body))
            }
        }
        return nil
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || trimmed == "***" || trimmed == "___"
    }

    private static let imageOnlyRegex = try! NSRegularExpression(
        pattern: #"^!\[[^\]]*\]\(([^)]+)\)$"#
    )

    private static func parseImageOnlyLine(_ line: String) -> NoteBlock? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let m = imageOnlyRegex.firstMatch(in: line, range: range), m.numberOfRanges == 2
        else { return nil }
        let url = (line as NSString).substring(with: m.range(at: 1))
        return .image(id: NoteBlockID.make(), url: url)
    }

    private static func parseTaskItem(line: String, level: Int) -> NoteBlock? {
        for marker in ["- [ ] ", "- [x] ", "* [ ] ", "* [x] "] {
            if line.hasPrefix(marker) {
                let checked = marker.contains("[x]")
                let body = String(line.dropFirst(marker.count))
                return .listItem(
                    id: NoteBlockID.make(),
                    kind: .task,
                    level: level,
                    checked: checked,
                    content: parseInlines(body)
                )
            }
        }
        return nil
    }

    private static func parseBulletItem(line: String, level: Int) -> NoteBlock? {
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                let body = String(line.dropFirst(marker.count))
                return .listItem(
                    id: NoteBlockID.make(),
                    kind: .bullet,
                    level: level,
                    checked: false,
                    content: parseInlines(body)
                )
            }
        }
        return nil
    }

    private static let orderedRegex = try! NSRegularExpression(pattern: #"^(\d+)\.\s+(.*)$"#)

    private static func parseOrderedItem(line: String, level: Int) -> NoteBlock? {
        let ns = line as NSString
        guard let m = orderedRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let body = ns.substring(with: m.range(at: 2))
        return .listItem(
            id: NoteBlockID.make(),
            kind: .ordered,
            level: level,
            checked: false,
            content: parseInlines(body)
        )
    }

    private static func isBlockBoundary(_ line: String) -> Bool {
        if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { return true }
        if isDivider(line) { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if orderedRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { return true }
        if parseImageOnlyLine(line) != nil { return true }
        return false
    }

    // MARK: - Inline parsing

    private static let placeRefRegex = try! NSRegularExpression(
        pattern: #"::place\[([^\]]*)\]\{#([^}]+)\}"#
    )

    /// Parse inline runs from a single logical line. Handles place chips
    /// first, then walks the remaining text for bold/italic/code spans.
    static func parseInlines(_ text: String) -> [InlineRun] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let matches = placeRefRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return parseFormattedRuns(in: text)
        }
        var runs: [InlineRun] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let segment = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                runs.append(contentsOf: parseFormattedRuns(in: segment))
            }
            let name = ns.substring(with: match.range(at: 1))
            let placeId = ns.substring(with: match.range(at: 2))
            runs.append(.placeRef(placeId: placeId, name: name))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            runs.append(contentsOf: parseFormattedRuns(in: tail))
        }
        return mergeAdjacentText(runs)
    }

    /// Very small recursive descent for `**bold**`, `*italic*`, `` `code` ``.
    /// Designed to be fast and forgiving — unmatched delimiters fall back to
    /// literal characters so user input is never lost.
    private static func parseFormattedRuns(in text: String) -> [InlineRun] {
        if text.isEmpty { return [] }
        var runs: [InlineRun] = []
        var buf = ""
        var current: InlineAttributes = []

        func flush() {
            if !buf.isEmpty {
                runs.append(.text(buf, attributes: current))
                buf = ""
            }
        }

        var i = text.startIndex
        while i < text.endIndex {
            let remaining = text[i...]
            if remaining.hasPrefix("**") {
                flush()
                current.formSymmetricDifference(.bold)
                i = text.index(i, offsetBy: 2)
                continue
            }
            if remaining.hasPrefix("*") {
                flush()
                current.formSymmetricDifference(.italic)
                i = text.index(after: i)
                continue
            }
            if remaining.hasPrefix("`") {
                flush()
                current.formSymmetricDifference(.code)
                i = text.index(after: i)
                continue
            }
            buf.append(text[i])
            i = text.index(after: i)
        }
        flush()
        return runs.filter { run in
            if case .text(let s, _) = run { return !s.isEmpty }
            return true
        }
    }

    private static func mergeAdjacentText(_ runs: [InlineRun]) -> [InlineRun] {
        var merged: [InlineRun] = []
        for run in runs {
            if case .text(let s, let attrs) = run,
               case .text(let prevS, let prevAttrs) = merged.last,
               prevAttrs == attrs {
                merged[merged.count - 1] = .text(prevS + s, attributes: attrs)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    // MARK: - Inline serialization

    private static func serializeInlines(_ runs: [InlineRun]) -> String {
        var out = ""
        for run in runs {
            switch run {
            case .text(let s, let attrs):
                out += wrapAttrs(s, attrs: attrs)
            case .placeRef(let placeId, let name):
                out += "::place[\(name)]{#\(placeId)}"
            }
        }
        return out
    }

    private static func wrapAttrs(_ s: String, attrs: InlineAttributes) -> String {
        var out = s
        if attrs.contains(.code) { out = "`\(out)`" }
        if attrs.contains(.italic) { out = "*\(out)*" }
        if attrs.contains(.bold) { out = "**\(out)**" }
        return out
    }
}
