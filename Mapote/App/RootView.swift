import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: NoteStore

    var body: some View {
        Group {
            if let note = store.currentNote {
                NoteEditorScreen(noteID: note.id)
            } else {
                NoteListScreen()
            }
        }
        .tint(AppTheme.primary)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

