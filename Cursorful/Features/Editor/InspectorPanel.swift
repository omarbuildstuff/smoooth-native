import SwiftUI

struct InspectorPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                section("Mockup") {
                    Toggle("Enable", isOn: Binding(
                        get: { vm.model.project.mockup.enabled },
                        set: { v in
                            vm.model.project.mockup.enabled = v
                            vm.renderer.renderMockup = v
                            try? vm.renderer.rebuildEffects()
                        }
                    ))
                    sliderRow(label: "Padding",
                              value: Binding(
                                get: { vm.model.project.mockup.paddingRatio },
                                set: { v in
                                    vm.model.project.mockup.paddingRatio = v
                                    vm.renderer.mockupEffect.settings.paddingRatio = v
                                }),
                              range: 0...0.25)
                    sliderRow(label: "Radius",
                              value: Binding(
                                get: { vm.model.project.mockup.cornerRadius },
                                set: { v in
                                    vm.model.project.mockup.cornerRadius = v
                                    vm.renderer.mockupEffect.settings.cornerRadius = v
                                }),
                              range: 0...0.05)
                    sliderRow(label: "Shadow",
                              value: Binding(
                                get: { vm.model.project.mockup.shadowStrength },
                                set: { v in
                                    vm.model.project.mockup.shadowStrength = v
                                    vm.renderer.mockupEffect.settings.shadowStrength = v
                                }),
                              range: 0...1)
                }

                section("Cursor") {
                    Toggle("Enable", isOn: Binding(
                        get: { vm.model.project.cursor.enabled },
                        set: { v in
                            vm.model.project.cursor.enabled = v
                            vm.renderer.renderCursor = v
                            try? vm.renderer.rebuildEffects()
                        }
                    ))
                    Toggle("Click ripples", isOn: Binding(
                        get: { vm.model.project.cursor.showRipples },
                        set: { v in
                            vm.model.project.cursor.showRipples = v
                            vm.renderer.renderRipples = v
                            try? vm.renderer.rebuildEffects()
                        }
                    ))
                    sliderRow(label: "Size",
                              value: Binding(
                                get: { vm.model.project.cursor.size },
                                set: { v in
                                    vm.model.project.cursor.size = v
                                    vm.renderer.cursorEffect.size = v
                                }),
                              range: 0.01...0.05)
                }

                section("Auto-Zoom") {
                    HStack {
                        Text("Regions").font(Typography.small).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(vm.model.project.zoomTrack.count)")
                            .font(Typography.tc.weight(.semibold))
                    }
                    Button("Regenerate from clicks") {
                        vm.model.generateAutoZoom(clicks: vm.events.clicks)
                        vm.renderer.zoomRegions = vm.model.project.zoomTrack
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Clear") {
                        vm.model.project.zoomTrack.removeAll()
                        vm.renderer.zoomRegions = []
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(Spacing.l)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title.uppercased())
                .font(Typography.small.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(.white.opacity(0.03))
        )
    }

    @ViewBuilder
    private func sliderRow(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Typography.small).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", Double(value.wrappedValue)))
                    .font(Typography.tc)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
