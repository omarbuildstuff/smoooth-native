import SwiftUI

/// The default app window. Shows recent recordings, a big Record button, and a sidebar.
struct MainWindowView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var recordings: [RecordingPackage] = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            mainArea
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(.black.opacity(0.98))
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
        .onChange(of: env.lastRecording?.id) { _, _ in refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Image(systemName: Icons.recordFill).foregroundStyle(.red)
                Text("Cursorful").font(Typography.header.weight(.bold))
                Spacer()
            }

            Divider().opacity(0.2)

            sidebarItem(icon: Icons.recordFill, title: "Record",   selected: true)
            sidebarItem(icon: Icons.folder,     title: "Library",  selected: false)
            sidebarItem(icon: Icons.settings,   title: "Settings", selected: false)

            Spacer()
            Text("v0.1")
                .font(Typography.small)
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.m)
        .frame(width: 200)
        .background(.black.opacity(0.35))
    }

    private func sidebarItem(icon: String, title: String, selected: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon).font(.system(size: 12))
            Text(title).font(Typography.body)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Spacing.s)
        .foregroundStyle(selected ? Color.white : .secondary)
        .background(
            RoundedRectangle(cornerRadius: Radius.s)
                .fill(selected ? Color.white.opacity(0.08) : .clear)
        )
    }

    private var mainArea: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            recordCTA
            librarySection
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }

    private var recordCTA: some View {
        VStack(spacing: Spacing.m) {
            Text("Start a recording")
                .font(Typography.header.weight(.bold))

            Text("⇧⌘2 to record fullscreen • ⇧⌘. to stop")
                .font(Typography.small)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.m) {
                PillButton(systemImage: Icons.display, label: "Record Screen", tint: .red) {
                    Task { await env.coordinator.startRecording() }
                }
                PillButton(systemImage: Icons.window, label: "Record Window", tint: Palette.accent) {
                    Task { await env.coordinator.startRecording(mode: .window) }
                }
            }

            if !env.permissions.hasScreenRecording {
                HStack(spacing: 6) {
                    Image(systemName: Icons.warning).foregroundStyle(.orange)
                    Text("Screen Recording permission required.")
                        .font(Typography.small)
                }
                .padding(.top, Spacing.s)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var librarySection: some View {
        if !recordings.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Recent Recordings").font(Typography.body.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.m) {
                        ForEach(recordings, id: \.id) { pkg in
                            RecordingTile(package: pkg)
                                .onTapGesture {
                                    (NSApp.delegate as? AppDelegate)?.showEditor(for: pkg)
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: 700)
        }
    }

    private func refresh() {
        recordings = env.recordingStore.list()
    }
}

private struct RecordingTile: View {
    let package: RecordingPackage
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(LinearGradient(colors: [.indigo.opacity(0.6), .purple.opacity(0.3)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 220, height: 124)
                .overlay(Image(systemName: Icons.play).foregroundStyle(.white.opacity(0.8)).font(.system(size: 24)))

            Text(package.id.uuidString.prefix(8).description)
                .font(Typography.small).foregroundStyle(.secondary)
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        Form {
            Section("Permissions") {
                Button("Open Permissions Window") {
                    (NSApp.delegate as? AppDelegate)?.showPermissionsWindow()
                }
            }
            Section("Storage") {
                let url = RecordingStore.rootURL
                LabeledContent("Recording Folder") {
                    Button(url.path) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
    }
}
