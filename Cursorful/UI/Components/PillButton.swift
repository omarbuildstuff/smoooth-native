import SwiftUI

struct PillButton: View {
    let systemImage: String?
    let label: String?
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    init(systemImage: String? = nil,
         label: String? = nil,
         tint: Color = Palette.accent,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let label {
                    Text(label).font(Typography.body.weight(.semibold))
                }
            }
            .padding(.vertical, Spacing.s)
            .padding(.horizontal, Spacing.l)
            .foregroundStyle(.white)
            .background(tint.opacity(hovered ? 1.0 : 0.9),
                        in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
            .scaleEffect(hovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovered = h } }
    }
}

struct IconButton: View {
    let systemImage: String
    var size: CGFloat = 28
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .background(
                    Circle().fill(.white.opacity(hovered ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovered = h } }
    }
}
