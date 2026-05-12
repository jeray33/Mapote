import SwiftUI

struct MapotePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.9 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct MapoteSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(AppTheme.paper.opacity(configuration.isPressed ? 0.9 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct MapoteDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(AppTheme.destructive.opacity(configuration.isPressed ? 0.9 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension ButtonStyle where Self == MapotePrimaryButtonStyle {
    static var mapotePrimary: MapotePrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == MapoteSecondaryButtonStyle {
    static var mapoteSecondary: MapoteSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == MapoteDangerButtonStyle {
    static var mapoteDanger: MapoteDangerButtonStyle { .init() }
}
