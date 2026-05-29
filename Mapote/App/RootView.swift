import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: NoteStore

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            if let note = store.currentNote {
                NoteEditorScreen(noteID: note.id)
                    .background(AppTheme.background.ignoresSafeArea())
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.08), radius: 8, x: -4, y: 0)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
                    .zIndex(1)
            } else {
                NoteListScreen()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .trailing)
                    ))
                    .zIndex(0)
            }
        }
        .animation(.spring(response: 0.62, dampingFraction: 0.94, blendDuration: 0.12), value: store.selectedNoteID)
        .tint(AppTheme.primary)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

