import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var browser: MemoryBrowser
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { browser.sidebarSelection },
            set: { if let value = $0 { browser.sidebarSelection = value } }
        )
    }

    private var activeWorkstreams: [WorkstreamSummary] {
        browser.workstreams.filter { $0.taskCount > 0 }
    }

    var body: some View {
        List(selection: selection) {
            Section {
                Label("Recent", systemImage: Glyph.recent)
                    .tag(SidebarItem.recent)
                Label("Today", systemImage: Glyph.today)
                    .tag(SidebarItem.today)
                Label("Pinned", systemImage: Glyph.pinned)
                    .tag(SidebarItem.pinned)
            }

            Section("Intelligence") {
                Label("Patterns", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .tag(SidebarItem.patterns)
                Label("Skills", systemImage: "wand.and.stars")
                    .tag(SidebarItem.skills)
            }

            if !activeWorkstreams.isEmpty {
                Section("Projects") {
                    ForEach(activeWorkstreams) { summary in
                        Label(summary.workstream.displayName, systemImage: summary.workstream.kind.glyph)
                            .badge(summary.taskCount)
                            .help(showsDeveloperDetails
                                ? "\(summary.workstream.kind.label) · \(summary.workstream.canonicalKey)"
                                : summary.workstream.displayName)
                            .tag(SidebarItem.workstream(summary.workstream.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureStatusBar()
        }
    }
}

/// The persistent status footer: what Mnemos is doing, and one control to
/// change it.
struct CaptureStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                StatusDot(tint: model.status.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.status.rawValue)
                        .font(.caption.weight(.semibold))
                    Text("Stored on this Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.xs)

                if model.agentAccessEnabled {
                    Image(systemName: Glyph.agents)
                        .font(.caption)
                        .foregroundStyle(model.agentAPIStatus.tint)
                        .help("Agent access: \(model.agentAPIStatus.label)")
                        .accessibilityLabel("Agent access \(model.agentAPIStatus.label)")
                }

                Button {
                    model.toggleCapture()
                } label: {
                    Image(systemName: model.isRunning ? Glyph.pause : Glyph.resume)
                        .font(.caption)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help(model.isRunning ? "Pause recording" : "Start recording")
                .accessibilityLabel(model.isRunning ? "Pause recording" : "Start recording")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s + 1)
        }
        .background(.bar)
    }
}
