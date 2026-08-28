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
                .toolbar {
                    ToolbarItem {
                        Button {
                            showsInspector.toggle()
                        } label: {
                            Label("Sources", systemImage: Glyph.inspector)
                        }
                        .help(showsInspector ? "Hide sources" : "Show what Mnemos saw")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { WindowActions.shared.register(openWindow) }
    }

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
        } else {
            TaskDetailPlaceholder(selectedCount: browser.selectedTaskIDs.count)
                .navigationTitle("Memory")
        }
    }
}

private struct PersonalLayerPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: title == "Skills" ? "wand.and.stars" : "point.3.filled.connected.trianglepath.dotted")
        } description: {
            Text(message)
        }
        .navigationTitle(title)
    }
}
