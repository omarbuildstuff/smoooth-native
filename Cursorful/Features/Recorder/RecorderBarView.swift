import SwiftUI

/// The floating recorder capsule. Shows elapsed time and a stop button while recording.
struct RecorderBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 1.0 : 0.3)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

            Text(timeString)
                .font(Typography.tc.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

            Spacer(minLength: Spacing.s)

            IconButton(systemImage: Icons.stop, tint: .red) {
                Task { await env.coordinator.stopRecording() }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.7))
                .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        )
        .onAppear { startTimer(); pulse = true }
        .onDisappear { stopTimer() }
    }

    @State private var pulse = false

    private var timeString: String {
        let total = Int(elapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func startTimer() {
        elapsed = 0
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            elapsed = Date().timeIntervalSince(start)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
