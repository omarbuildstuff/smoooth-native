import SwiftUI

struct PermissionsWindowView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            header

            VStack(spacing: Spacing.m) {
                PermissionRow(
                    title: "Screen Recording",
                    subtitle: "Required — capture your screen.",
                    granted: env.permissions.hasScreenRecording,
                    primaryLabel: env.permissions.hasScreenRecording ? "Granted" : "Grant",
                    action: { env.permissions.requestScreenRecording() },
                    secondaryAction: { env.permissions.openScreenRecordingSettings() }
                )
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Required — track mouse clicks for auto-zoom.",
                    granted: env.permissions.hasAccessibility,
                    primaryLabel: env.permissions.hasAccessibility ? "Granted" : "Open Settings",
                    action: { env.permissions.requestAccessibility() }
                )
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Optional — record narration.",
                    granted: env.permissions.hasMicrophone,
                    primaryLabel: env.permissions.hasMicrophone ? "Granted" : "Grant",
                    action: { env.permissions.requestMicrophone() }
                )
                PermissionRow(
                    title: "Camera",
                    subtitle: "Optional — webcam picture-in-picture.",
                    granted: env.permissions.hasCamera,
                    primaryLabel: env.permissions.hasCamera ? "Granted" : "Grant",
                    action: { env.permissions.requestCamera() }
                )
            }

            Divider().opacity(0.3)

            HStack {
                Button("Refresh") { env.permissions.refresh() }
                    .buttonStyle(.bordered)

                Spacer()

                Text("If a toggle doesn't stick, relaunch Cursorful.")
                    .font(Typography.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(Palette.accent)
            Text("Grant permissions")
                .font(Typography.header.weight(.bold))
            Text("Cursorful needs these to record and track cursor activity.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let primaryLabel: String
    let action: () -> Void
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: granted ? Icons.check : Icons.xmarkCircle)
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color.green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.body.weight(.semibold))
                Text(subtitle).font(Typography.small).foregroundStyle(.secondary)
            }
            Spacer()

            Button(primaryLabel, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(granted)
        }
        .padding(Spacing.m)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}
