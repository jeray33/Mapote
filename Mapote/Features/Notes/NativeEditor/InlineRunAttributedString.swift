import SwiftUI

// Build a SwiftUI AttributedString from a list of inline runs.
//
// Place chips are encoded as a custom `mapote-place://<id>` URL inside the
// `.link` attribute so SwiftUI's Text can route taps via `OpenURLAction`.
// This keeps the renderer a single `Text` and avoids hand-rolling a wrap
// layout for mixed text / chip rows (Phase 7 can upgrade to a pill UI).
enum InlineRunAttributedString {
    static let placeURLScheme = "mapote-place"

    static func make(_ runs: [InlineRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .text(let s, let attrs):
                var part = AttributedString(s)
                var intent: InlinePresentationIntent = []
                if attrs.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if attrs.contains(.italic) { intent.insert(.emphasized) }
                if attrs.contains(.code) { intent.insert(.code) }
                if !intent.isEmpty {
                    part.inlinePresentationIntent = intent
                }
                result += part
            case .placeRef(let placeId, let name):
                let hair = "\u{200A}"
                var chip = AttributedString(hair + name + hair)
                chip.foregroundColor = AppTheme.primary
                chip.backgroundColor = AppTheme.primary.opacity(0.12)
                chip.font = .system(size: 17, weight: .semibold)
                chip.link = URL(string: "\(placeURLScheme)://\(placeId)")
                result += chip
            }
        }
        return result
    }

    static func extractPlaceID(from url: URL) -> String? {
        guard url.scheme == placeURLScheme else { return nil }
        return url.host
    }
}
