import SwiftUI

// Floating action bar shown while in multi-select mode. Mirrors the
// existing WebView bar's visual language (count + copy + delete) but is
// a pure SwiftUI view, so it can share the editor's MainActor state and
// route taps through the NoteBlockController without a bridge.
struct SelectionActionBar: View {
    let count: Int
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("已选 \(count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)

            Spacer(minLength: 8)

            Button(action: onCopy) {
                Text("复制")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.06))
                    .foregroundStyle(AppTheme.foreground)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)

            Button(action: onDelete) {
                Text("删除")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .padding(8)
                    .background(Color.black.opacity(0.06))
                    .foregroundStyle(AppTheme.foreground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 8)
        .padding(.horizontal, 12)
    }
}
