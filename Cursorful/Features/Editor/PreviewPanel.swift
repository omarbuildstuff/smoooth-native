import SwiftUI

struct PreviewPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        ZStack {
            Color.black
            PreviewView(renderer: vm.renderer)
                .aspectRatio(aspect, contentMode: .fit)
                .padding(Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var aspect: CGFloat {
        let s = vm.model.project.sourceSize
        guard s.width > 0, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }
}
