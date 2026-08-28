import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var browser: MemoryBrowser
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
        if let task = browser.selectedTask {
            TaskDetailView(task: task)
        } else {
            TaskDetailPlaceholder(selectedCount: browser.selectedTaskIDs.count)
                .navigationTitle("Memory")
        }
    }
}
