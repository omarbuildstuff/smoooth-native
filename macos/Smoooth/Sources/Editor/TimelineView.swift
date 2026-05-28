import SwiftUI
import SmooothCore

/// Visual timeline: ruler + playhead + draggable zoom/cut/speed region blocks.
/// Matches the original React Timeline: rounded card with scissor end-strips, a
/// ruler with ticks/labels, primary/red/amber region blocks, and a blue playhead.
struct TimelineView: View {
    @Bindable var model: EditorModel
    @Environment(\.theme) private var theme

    private var hasSpeed: Bool { !model.speedRegions.isEmpty }

    var body: some View {
        let container = HStack(spacing: 0) {
            endStrip(icon: "scissors")
            timelineBody
            endStrip(icon: "scissors", flip: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusXl, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)

        return container
            .padding(12)
            .frame(height: hasSpeed ? 224 : 176)
            .background(theme.background)
            .animation(.easeInOut(duration: 0.25), value: hasSpeed)
    }

    private func endStrip(icon: String, flip: Bool = false) -> some View {
        ZStack {
            theme.card
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(theme.mutedForeground)
                .scaleEffect(x: flip ? -1 : 1, y: 1)
        }
        .frame(width: 32)
        .overlay(alignment: flip ? .leading : .trailing) {
            Rectangle().fill(theme.border).frame(width: 1)
        }
    }

    private var timelineBody: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let dur = max(0.001, model.duration)
            let pps = width / dur
            let laneTop: CGFloat = 40

            ZStack(alignment: .topLeading) {
                theme.card

                // Ruler
                ruler(pps: pps, dur: dur, height: geo.size.height)

                // Region lanes. When speed regions exist, zoom/cut occupy the top
                // half and speed the bottom half (mirrors the original layout).
                let laneAreaHeight = geo.size.height - laneTop
                let topLaneHeight = hasSpeed ? laneAreaHeight / 2 : laneAreaHeight

                ForEach(zoomRegions) { r in
                    regionBlock(r, pps: pps, color: theme.zoom, icon: "magnifyingglass", label: "ZOOM",
                                topInset: laneTop, laneHeight: topLaneHeight)
                }
                ForEach(cutRegions) { r in
                    regionBlock(r, pps: pps, color: theme.cut, icon: "scissors", label: "CUT",
                                topInset: laneTop, laneHeight: topLaneHeight)
                }
                ForEach(speedRegions) { r in
                    regionBlock(r, pps: pps, color: theme.speed, icon: "forward.fill", label: "\(speedLabel(r.id))x",
                                topInset: hasSpeed ? laneTop + topLaneHeight : laneTop, laneHeight: topLaneHeight)
                }

                // Playhead
                playhead(pps: pps, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                model.seek(to: v.location.x / pps)
            })
        }
    }

    // MARK: - Ruler

    private func ruler(pps: Double, dur: Double, height: CGFloat) -> some View {
        let interval = Geometry.rulerInterval(pixelsPerSecond: pps)
        return ZStack(alignment: .topLeading) {
            // header band
            theme.card.opacity(0.6).frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border.opacity(0.6)).frame(height: 1) }

            ForEach(Array(stride(from: 0.0, through: dur, by: interval.major)), id: \.self) { t in
                let x = t * pps
                // major tick
                Rectangle().fill(theme.mutedForeground.opacity(0.5))
                    .frame(width: 1, height: 18)
                    .offset(x: x, y: 8)
                Text(timeLabel(t))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.foreground.opacity(0.7))
                    .offset(x: x + 4, y: 12)
            }
        }
    }

    // MARK: - Region block

    @ViewBuilder
    private func regionBlock(_ r: Region, pps: Double, color: Color, icon: String, label: String,
                             topInset: CGFloat, laneHeight: CGFloat) -> some View {
        let selected = model.selectedRegionID == r.id
        let blockHeight = min(56, max(28, laneHeight - 8))
        let blockWidth = max(8, r.dur * pps)

        RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous)
            .fill(theme.card.opacity(selected ? 0.95 : 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous)
                    .strokeBorder(selected ? color : color.opacity(0.55), lineWidth: 2)
            )
            .overlay(alignment: .leading) {
                Capsule().fill(color).frame(width: 3, height: blockHeight * 0.5).padding(.leading, 6)
            }
            .overlay(alignment: .trailing) {
                Capsule().fill(color).frame(width: 3, height: blockHeight * 0.5).padding(.trailing, 6)
            }
            .overlay {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    Text(label).font(.system(size: 11, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 8)
            }
            .shadow(color: selected ? color.opacity(0.25) : .clear, radius: 8, x: 0, y: 2)
            .frame(width: blockWidth, height: blockHeight)
            .offset(x: r.start * pps, y: topInset + (laneHeight - blockHeight) / 2)
            .onTapGesture { model.selectedRegionID = r.id; selectTab(r.kind) }
            .gesture(DragGesture()
                .onChanged { v in
                    model.beginInteractiveEdit()
                    let newStart = max(0, min(model.duration - r.dur, (r.start * pps + v.translation.width) / pps))
                    model.setRegionStartLive(r.id, newStart)
                }
                .onEnded { _ in model.endInteractiveEdit("Move Region") })
    }

    // MARK: - Playhead

    private func playhead(pps: Double, height: CGFloat) -> some View {
        let px = model.currentTime * pps
        return ZStack(alignment: .top) {
            // line
            Rectangle().fill(theme.primary).frame(width: 2, height: height)
            // triangle head
            Triangle().fill(theme.primary)
                .frame(width: 14, height: 9)
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
        }
        .frame(width: 14, alignment: .top)
        .offset(x: px - 7)
        .allowsHitTesting(false)
    }

    // MARK: - Region collections

    private enum Kind { case zoom, cut, speed }
    private struct Region: Identifiable { let id: String; let start: Double; let dur: Double; let kind: Kind }

    private var zoomRegions: [Region] {
        model.zoomRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .zoom) }
    }
    private var cutRegions: [Region] {
        model.cutRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .cut) }
    }
    private var speedRegions: [Region] {
        model.speedRegions.values.map { Region(id: $0.id, start: $0.startTime, dur: $0.duration, kind: .speed) }
    }

    private func speedLabel(_ id: String) -> String {
        guard let s = model.speedRegions[id]?.speed else { return "" }
        return (s == s.rounded()) ? String(Int(s)) : String(format: "%.2g", s)
    }

    private func selectTab(_ kind: Kind) {
        if kind == .zoom || kind == .speed { model.activeSidePanelTab = .animation }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Downward-pointing triangle for the playhead head.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
