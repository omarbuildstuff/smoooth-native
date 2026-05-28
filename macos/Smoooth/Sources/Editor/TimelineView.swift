import SwiftUI
import SmooothCore

/// Visual timeline: ruler + playhead + draggable zoom/cut/speed region blocks.
struct TimelineView: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let dur = max(0.001, model.duration)
            let pps = width / dur

            ZStack(alignment: .topLeading) {
                Color(NSColor.controlBackgroundColor)

                // Ruler ticks
                let interval = Geometry.rulerInterval(pixelsPerSecond: pps)
                ForEach(Array(stride(from: 0.0, through: dur, by: interval.major)), id: \.self) { t in
                    let x = t * pps
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height)) }
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    Text(timeLabel(t)).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary).position(x: x + 16, y: 8)
                }

                // Region lanes
                VStack(spacing: 4) {
                    lane(model.zoomRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .zoom) }, pps: pps, color: .blue, y: 0)
                    lane(model.cutRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .cut) }, pps: pps, color: .red, y: 0)
                    lane(model.speedRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .speed) }, pps: pps, color: .orange, y: 0)
                }
                .padding(.top, 22)
                .padding(.horizontal, 0)

                // Playhead
                let px = model.currentTime * pps
                Path { p in p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: geo.size.height)) }
                    .stroke(Color.accentColor, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                model.seek(to: v.location.x / pps)
            })
        }
        .frame(height: 140)
    }

    private enum Kind { case zoom, cut, speed }
    private struct Region: Identifiable { let id: String; let start: Double; let dur: Double; let kind: Kind }

    @ViewBuilder private func lane(_ regions: [Region], pps: Double, color: Color, y: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 30)
            ForEach(regions) { r in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(model.selectedRegionID == r.id ? 0.85 : 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.selectedRegionID == r.id ? Color.white : .clear, lineWidth: 1.5))
                    .frame(width: max(6, r.dur * pps), height: 28)
                    .offset(x: r.start * pps)
                    .onTapGesture { model.selectedRegionID = r.id; selectTab(r.kind) }
                    .gesture(DragGesture()
                        .onChanged { v in
                            model.beginInteractiveEdit()
                            let newStart = max(0, min(model.duration - r.dur, (r.start * pps + v.translation.width) / pps))
                            model.setRegionStartLive(r.id, newStart)
                        }
                        .onEnded { _ in model.endInteractiveEdit("Move Region") })
            }
        }
        .frame(height: 30)
    }

    private func selectTab(_ kind: Kind) {
        if kind == .zoom || kind == .speed { model.activeSidePanelTab = .animation }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
