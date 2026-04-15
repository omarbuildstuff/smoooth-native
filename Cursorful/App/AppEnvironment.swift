import Foundation
import Combine

/// Dependency container. Lazily instantiated singletons held here so SwiftUI views and AppKit
/// controllers can all reach the same state without prop-drilling.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let permissions: PermissionsChecker
    let recordingStore: RecordingStore
    let coordinator: RecordingCoordinator

    @Published var lastRecording: RecordingPackage?
    @Published var recorderVisible: Bool = false

    private init() {
        self.permissions = PermissionsChecker()
        self.recordingStore = RecordingStore()
        self.coordinator = RecordingCoordinator(store: recordingStore)

        // Forward latest recording to the environment when the coordinator finishes.
        coordinator.onFinish = { [weak self] pkg in
            Task { @MainActor in
                self?.lastRecording = pkg
            }
        }
    }
}
