import Foundation

// Single switch for migrating off the WKWebView editor.
// Default: ON now that the native editor covers the full feature set.
// Override via UserDefaults (`native-editor-enabled` set to `false`) to
// fall back to the legacy WebView for A/B testing.
enum NativeEditorFeatureFlag {
    static let key = "native-editor-enabled"
    static let defaultEnabled = true

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return defaultEnabled }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

// One-shot facade used by NoteStore-style call sites: load a Note into a
// NoteDocument (prefer persisted blocks, fall back to Markdown), and write
// a NoteDocument back to both Markdown + blocks so legacy services keep
// working unchanged.
enum NoteDocumentBridge {
    static func loadDocument(from note: Note) -> NoteDocument {
        if let decoded = NoteBlockCodec.decode(note.blocks), !decoded.isEmpty {
            return decoded
        }
        return NoteBlockMarkdown.parse(note.markdown)
    }

    static func materialize(_ document: NoteDocument) -> (markdown: String, blocks: Data?) {
        let markdown = NoteBlockMarkdown.serialize(document)
        let blocks = NoteBlockCodec.encode(document)
        return (markdown, blocks)
    }
}
