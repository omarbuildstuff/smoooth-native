import SwiftUI

struct GlassPanel<Content: View>: View {
    var radius: CGFloat = Radius.l
    var material: Material = Surfaces.chrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
