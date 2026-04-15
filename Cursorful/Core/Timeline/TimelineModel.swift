import Combine
import CoreMedia
import Foundation

/// Central edit state for the editor. Owns the `Project` and broadcasts changes so both the
/// renderer and the timeline view stay in sync.
@MainActor
final class TimelineModel: ObservableObject {
    let package: RecordingPackage
    @Published var project: Project
    @Published var playhead: CMTime = .zero
    @Published var pixelsPerSecond: CGFloat = 80

    init(package: RecordingPackage, project: Project) {
        self.package = package
        self.project = project
    }

    // MARK: - Zoom regions

    func addZoomRegion(_ region: ZoomRegion) {
        project.zoomTrack.append(region)
        project.zoomTrack.sort { $0.start < $1.start }
    }

    func removeZoomRegion(id: UUID) {
        project.zoomTrack.removeAll { $0.id == id }
    }

    func updateZoomRegion(_ region: ZoomRegion) {
        if let idx = project.zoomTrack.firstIndex(where: { $0.id == region.id }) {
            project.zoomTrack[idx] = region
        }
    }

    /// Seed zoom track from the recorded click log.
    func generateAutoZoom(clicks: [ClickEvent]) {
        let regions = AutoZoomPlanner.plan(
            clicks: clicks,
            sourceSize: project.sourceSize,
            totalDuration: project.sourceDuration
        )
        project.zoomTrack = regions
    }

    // MARK: - Save

    func save() {
        do {
            try project.save(to: package)
        } catch {
            Log.timeline.error("Project save failed: \(error.localizedDescription)")
        }
    }
}
