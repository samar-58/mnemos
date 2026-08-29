import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var browser: MemoryBrowser
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showsEvidenceInspector") private var showsInspector = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            TaskListView()
        } detail: {
            detail
                .inspector(isPresented: $showsInspector) {
                    EvidenceInspector()
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
                }
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { WindowActions.shared.register(openWindow) }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Sources", systemImage: Glyph.inspector)
            }
            .help(showsInspector ? "Hide sources" : "Show what Mnemos saw")
        }

        ToolbarItem {
            SettingsLink {
                Label("Settings", systemImage: Glyph.settings)
            }
            .help("Settings")
        }
    }

    /// The detail pane follows the selection: a timeline group, a single
    /// session, or the reason there is nothing to show.
    @ViewBuilder
    private var detail: some View {
        if browser.sidebarSelection == .patterns {
            if let pattern = model.workflowPatterns.first(where: { $0.id == browser.selectedPatternID }) {
                PatternDetailView(pattern: pattern)
            } else {
                PersonalLayerPlaceholder(
                    title: "Patterns",
                    message: "Repeated workflows are computed locally from action sequences. A model may explain a supported pattern, but it cannot invent one."
                )
            }
        } else if browser.sidebarSelection == .skills {
            if let id = browser.selectedSkillID, model.personalSkills.contains(where: { $0.id == id }) {
                SkillDetailView(skillID: id)
            } else {
                PersonalLayerPlaceholder(
                    title: "Skills",
                    message: "Only skills you approve can become trusted agent instructions. Candidate memories and captured evidence remain untrusted."
                )
            }
        } else if let task = browser.selectedTask {
            TaskDetailView(task: task)
        } else if let group = selectedGroup {
            TaskGroupDetailView(entry: group)
                .id(group.id)
        } else {
            TaskDetailPlaceholder()
                .navigationTitle("Memory")
        }
    }

    /// A rolled-up group opened from the list, or an ad-hoc one for a
    /// hand-picked set of rows — several sessions selected by hand deserve the
    /// same combined view as a group the timeline built.
    private var selectedGroup: TimelineGroup? {
        if let group = browser.selectedGroup { return group }
        let tasks = browser.selectedTasks
        guard tasks.count > 1 else { return nil }
        return TimelineGroup(tasks: tasks, workstreamID: tasks[0].workstream?.id)
    }
}

private struct PersonalLayerPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: title == "Skills" ? Glyph.skills : Glyph.patterns)
        } description: {
            Text(message)
        }
        .navigationTitle(title)
    }
}
