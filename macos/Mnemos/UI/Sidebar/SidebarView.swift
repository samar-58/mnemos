import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var browser: MemoryBrowser
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false
    @State private var showsAllProjects = false

    /// How many projects the sidebar shows before it offers to reveal the rest.
    /// A memory app accumulates projects indefinitely; a sidebar that grows
    /// without limit stops being navigable.
    private static let collapsedProjectLimit = 6

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { browser.sidebarSelection },
            set: { if let value = $0 { browser.sidebarSelection = value } }
        )
    }

    private var projects: [WorkstreamSummary] {
        let all = browser.sidebarProjects
        guard !showsAllProjects, all.count > Self.collapsedProjectLimit else { return all }
        return Array(all.prefix(Self.collapsedProjectLimit))
    }

    var body: some View {
        List(selection: selection) {
            Section {
                row("Recent", Glyph.recent, .recent)
                row("Today", Glyph.today, .today)
                row("Pinned", Glyph.pinned, .pinned)
            }

            Section("Intelligence") {
                row("Patterns", Glyph.patterns, .patterns)
                row("Skills", Glyph.skills, .skills)
            }

            if !browser.sidebarProjects.isEmpty {
                Section {
                    ForEach(projects) { summary in
                        Label(
                            ProjectName.display(summary.workstream.displayName),
                            systemImage: summary.workstream.kind.glyph
                        )
                        .badge(summary.taskCount)
                        .help(helpText(for: summary))
                        .tag(SidebarItem.workstream(summary.workstream.id))
                    }

                    if browser.sidebarProjects.count > Self.collapsedProjectLimit {
                        Button(showsAllProjects ? "Show fewer" : "Show all \(browser.sidebarProjects.count)") {
                            withAnimation(.snappy(duration: 0.2)) { showsAllProjects.toggle() }
                        }
                        .buttonStyle(.link)
                        .font(TypeScale.meta)
                        .selectionDisabled()
                    }
                } header: {
                    HStack(spacing: Spacing.xs) {
                        Text("Projects")
                        if browser.hiddenProjectCount > 0 {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("\(browser.hiddenProjectCount) more were detected from paths and links but had no readable name.")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureStatusBar()
        }
    }

    private func row(_ title: String, _ glyph: String, _ item: SidebarItem) -> some View {
        Label(title, systemImage: glyph).tag(item)
    }

    private func helpText(for summary: WorkstreamSummary) -> String {
        guard showsDeveloperDetails else { return summary.workstream.displayName }
        return "\(summary.workstream.kind.label) · \(summary.workstream.canonicalKey)"
    }
}

/// The persistent status footer: what Mnemos is doing, one control to change
/// it, and the way into Settings.
///
/// Settings sits here as well as in the app menu because this is where a person
/// looks when the thing they want to change is what Mnemos is recording, which
/// is the line directly above it.
struct CaptureStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                StatusDot(tint: model.status.tint, isPulsing: model.isRunning)

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.status.rawValue)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("Stored on this Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.accessoryBar)
                .help(model.isRunning ? "Pause recording" : "Start recording")
                .accessibilityLabel(model.isRunning ? "Pause recording" : "Start recording")

                SettingsLink {
                    Image(systemName: Glyph.settings)
                        .font(.caption)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.accessoryBar)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
        }
        .background(.bar)
    }
}
