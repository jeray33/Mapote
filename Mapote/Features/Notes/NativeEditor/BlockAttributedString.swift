import SwiftUI
import UIKit

// NSAttributedString conversion for UITextView-backed editing.
// Place chips travel as a custom attribute so we can recover them when
// parsing the text view's contents back into structured InlineRuns.
enum BlockAttributedString {
    static let placeIDKey = NSAttributedString.Key("mapote.place.id")

    struct Style {
        let font: UIFont
        let foreground: UIColor

        static let paragraph = Style(
            font: .systemFont(ofSize: 17, weight: .regular),
            foreground: .label
        )

        static let heading1 = Style(
            font: .systemFont(ofSize: 26, weight: .bold),
            foreground: .label
        )

        static let heading2 = Style(
            font: .systemFont(ofSize: 22, weight: .bold),
            foreground: .label
        )

        static let heading3 = Style(
            font: .systemFont(ofSize: 18, weight: .semibold),
            foreground: .label
        )

        static let listItem = Style(
            font: .systemFont(ofSize: 17, weight: .regular),
            foreground: .label
        )

        static func heading(level: Int) -> Style {
            switch level {
            case 1: return .heading1
            case 2: return .heading2
            default: return .heading3
            }
        }
    }

    static func make(_ runs: [InlineRun], style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            switch run {
            case .text(let s, let attrs):
                let part = NSAttributedString(
                    string: s,
                    attributes: textAttributes(base: style, inline: attrs)
                )
                result.append(part)
            case .placeRef(let id, let name):
                // Place chips render as a tinted, bold inline span with a
                // soft background — the closest we can get to a real pill
                // without leaving the NSAttributedString → UITextView
                // pipeline. Hair-spaces on either side give it visual
                // breathing room without affecting word-wrap.
                var attrs = textAttributes(base: style, inline: [.bold])
                attrs[.foregroundColor] = UIColor(AppTheme.primary)
                attrs[.backgroundColor] = UIColor(AppTheme.primary.opacity(0.12))
                attrs[placeIDKey] = id
                let hair = "\u{200A}"
                let part = NSAttributedString(string: hair + name + hair, attributes: attrs)
                result.append(part)
            }
        }
        if result.length == 0 {
            // UITextView's typingAttributes are derived from the existing
            // attributedText when non-empty; seed an empty placeholder so the
            // user's first keystroke inherits the right font.
            return NSAttributedString(
                string: "",
                attributes: textAttributes(base: style, inline: [])
            )
        }
        return result
    }

    static func parse(_ attributed: NSAttributedString) -> [InlineRun] {
        var runs: [InlineRun] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { dict, range, _ in
            let substring = (attributed.string as NSString).substring(with: range)
            if substring.isEmpty { return }
            if let placeID = dict[placeIDKey] as? String {
                // Strip the visual hair-space padding that `make` injects;
                // they are not part of the place name.
                let stripped = substring
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{200A}"))
                runs.append(.placeRef(placeId: placeID, name: stripped))
                return
            }
            var inline: InlineAttributes = []
            if let font = dict[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) { inline.insert(.bold) }
                if traits.contains(.traitItalic) { inline.insert(.italic) }
                if traits.contains(.traitMonoSpace) { inline.insert(.code) }
            }
            runs.append(.text(substring, attributes: inline))
        }
        return mergeAdjacentText(runs)
    }

    static func typingAttributes(for style: Style) -> [NSAttributedString.Key: Any] {
        textAttributes(base: style, inline: [])
    }

    // MARK: - Private

    private static func textAttributes(
        base: Style,
        inline: InlineAttributes
    ) -> [NSAttributedString.Key: Any] {
        let font = applyTraits(base.font, attrs: inline)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: base.foreground,
        ]
        if inline.contains(.code) {
            attrs[.backgroundColor] = UIColor.systemGray5
        }
        return attrs
    }

    private static func applyTraits(_ base: UIFont, attrs: InlineAttributes) -> UIFont {
        var traits = base.fontDescriptor.symbolicTraits
        if attrs.contains(.bold) { traits.insert(.traitBold) }
        if attrs.contains(.italic) { traits.insert(.traitItalic) }
        if attrs.contains(.code) { traits.insert(.traitMonoSpace) }
        if let desc = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: desc, size: base.pointSize)
        }
        return base
    }

    private static func mergeAdjacentText(_ runs: [InlineRun]) -> [InlineRun] {
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
}
