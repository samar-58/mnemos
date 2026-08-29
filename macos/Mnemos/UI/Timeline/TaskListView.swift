import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browser: MemoryBrowser

    /// The task a pending delete refers to, whether it came from the row menu
    /// or the Memory menu.
    private var pendingDelete: TaskMemory? {
        guard let id = browser.pendingDeleteID else { return nil }
        return browser.displayedTasks.first { $0.id == id } ?? browser.selectedTask
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
            .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search your memory")
            .searchScopes($browser.searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .onChange(of: browser.searchText) { _, _ in browser.searchTextDidChange() }
            .toolbar { filterMenu }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete this task?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { browser.pendingDeleteID = nil } }
                ),
                presenting: pendingDelete
            ) { task in
                Button("Delete", role: .destructive) {
                    browser.delete(taskID: task.id)
                    browser.pendingDeleteID = nil
                }
                Button("Cancel", role: .cancel) { browser.pendingDeleteID = nil }
            } message: { _ in
                Text("The recorded activity behind this task is deleted too. This can't be undone.")
            }
            .onAppear {
                browser.refresh()
                Task { await model.refreshPersonalInsights() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if browser.sidebarSelection == .patterns {
            patterns
        } else if browser.sidebarSelection == .skills {
            skills
        } else if browser.displayedTasks.isEmpty {
            if browser.isSearching {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.isFiltering {
                ContentUnavailableView {
                    Label("No matches", systemImage: Glyph.search)
                } description: {
                    Text("Try fewer words, a wider time range, or a different project.")
                } actions: {
                    Button("Clear filters", action: clearFilters)
                }
            } else {
                setupState
            }
        } else {
            list
        }
    }

    private var patterns: some View {
        List(model.workflowPatterns, selection: $browser.selectedPatternID) { pattern in
            HStack(alignment: .top, spacing: Spacing.s) {
                RowIcon(systemImage: Glyph.patterns)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Text(pattern.title)
                            .font(TypeScale.rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.s)
                        Text("\(Int(pattern.confidence * 100))%")
                            .font(TypeScale.numeric)
                            .foregroundStyle(.secondary)
                    }
                    Text(pattern.summary)
                        .font(TypeScale.rowBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(pattern.occurrenceCount) occurrences · \(pattern.status.rawValue.capitalized)")
                        .font(TypeScale.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Spacing.xs)
            .tag(pattern.id)
        }
        .listStyle(.inset)
        .overlay {
            if model.workflowPatterns.isEmpty {
                ContentUnavailableView(
                    "No reliable patterns yet", systemImage: "point.3.filled.connected.trianglepath.dotted",
                    description: Text("A workflow needs at least three similar occurrences across two days before Mnemos suggests it.")
                )
            }
        }
    }

    private var skills: some View {
        List(model.personalSkills, selection: $browser.selectedSkillID) { skill in
            HStack(alignment: .top, spacing: Spacing.s) {
                RowIcon(systemImage: Glyph.skills)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.s) {
                        Text(skill.title)
                            .font(TypeScale.rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.s)
                        SkillStatusChip(status: skill.status)
                    }
                    Text(skill.description)
                        .font(TypeScale.rowBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: Spacing.xs) {
                        Text("\(skill.occurrenceCount) workflows · \(Int(skill.confidence * 100))% confidence")
                        if model.skillActivity[skill.id]?.isExported == true {
                            Text("· Exported")
                        }
                    }
                    .font(TypeScale.meta)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Spacing.xs)
            .tag(skill.id)
        }
        .listStyle(.inset)
        .overlay {
            if model.personalSkills.isEmpty {
                ContentUnavailableView(
                    "No skill candidates yet", systemImage: "wand.and.stars",
                    description: Text("Mnemos only proposes skills after local pattern mining finds repeated behavior. Nothing is trusted by agents until you approve it.")
                )
            }
        }
    }

    private var list: some View {
        List(selection: $browser.selectedTaskIDs) {
            if let now = browser.nowTask {
                Section {
                    TaskRow(task: now, result: browser.result(for: now.id))
                        .tag(now.id)
                        .contextMenu { menu(for: now) }
                } header: {
                    SectionHeading(title: "Now")
                }
            }

            ForEach(browser.days) { day in
                Section {
                    ForEach(day.entries) { entry in
                        groupRows(entry)
                    }
                } header: {
                    SectionHeading(title: day.label, trailing: Elapsed.label(seconds: day.activeSeconds))
                }
            }

            if !browser.isFiltering, !browser.reachedEnd {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, Spacing.s)
                .selectionDisabled()
                .onAppear { browser.loadMore() }
            }
        }
        .listStyle(.inset)
        .onChange(of: browser.selectedTaskIDs) { _, _ in browser.selectionDidChange() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = browser.error {
                InlineBanner(message: error)
            }
        }
    }

    /// A single-episode entry is a plain row; a rolled-up one is a header that
    /// selects the whole group, with its episodes underneath when opened.
    @ViewBuilder
    private func groupRows(_ entry: TimelineGroup) -> some View {
        if entry.isGroup {
            TimelineGroupRow(
                entry: entry,
                isExpanded: browser.expandedGroupIDs.contains(entry.id),
                isSelected: browser.selectedGroupID == entry.id,
                onToggle: {
                    withAnimation(.snappy(duration: 0.2)) {
                        if browser.expandedGroupIDs.contains(entry.id) {
                            browser.expandedGroupIDs.remove(entry.id)
                        } else {
                            browser.expandedGroupIDs.insert(entry.id)
                        }
                    }
                },
                onSelect: { browser.selectGroup(entry) }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.xs, bottom: 0, trailing: Spacing.xs))
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .contextMenu { groupMenu(for: entry) }

            if browser.expandedGroupIDs.contains(entry.id) {
                ForEach(entry.tasks) { task in
                    TaskRow(task: task, result: browser.result(for: task.id), isNested: true)
                        .padding(.leading, Spacing.l)
                        .tag(task.id)
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(for: task) }
                }
            }
        } else {
            TaskRow(task: entry.lead, result: browser.result(for: entry.lead.id))
                .tag(entry.lead.id)
                .contextMenu { menu(for: entry.lead) }
        }
    }

    /// The first-run path: whatever is missing before memory can exist.
    @ViewBuilder
    private var setupState: some View {
        if !model.accessibilityTrusted {
            ContentUnavailableView {
                Label("Accessibility access needed", systemImage: Glyph.privacy)
            } description: {
                Text("Mnemos reads context from the apps you allow. Nothing leaves this Mac.")
            } actions: {
                Button("Set up") { model.presentSettings(.capture) }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.allowedBundleIDs.isEmpty {
            ContentUnavailableView {
                Label("No apps allowed yet", systemImage: Glyph.application)
            } description: {
                Text("Choose which apps Mnemos may observe. The list starts empty on purpose.")
            } actions: {
                Button("Choose apps") { model.presentSettings(.capture) }
                    .buttonStyle(.borderedProminent)
            }
        } else if !model.isRunning {
            ContentUnavailableView {
                Label("Not recording", systemImage: Glyph.live)
            } description: {
                Text(model.status.detail)
            } actions: {
                Button("Start recording") { model.toggleCapture() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing recorded yet", systemImage: Glyph.task)
            } description: {
                Text("Keep working. Mnemos groups your activity into tasks as it goes.")
            }
        }
    }

    @ToolbarContentBuilder
    private var filterMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Filter by app", selection: $browser.applicationFilter) {
                    Text("All apps").tag(String?.none)
                    Divider()
                    ForEach(browser.availableApplications, id: \.self) { application in
                        Text(application).tag(String?.some(application))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(
                    "Filter by app",
                    systemImage: browser.applicationFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .help("Filter by app")
            .disabled(browser.availableApplications.isEmpty && browser.applicationFilter == nil)
        }
    }

    /// Actions on a whole rolled-up entry. Merging is offered here because the
    /// roll-up only hides the fragmentation — merging is how a person makes the
    /// grouping permanent, so the store, search, and the agent API agree with
    /// what the list shows.
    @ViewBuilder
    private func groupMenu(for entry: TimelineGroup) -> some View {
        Button(browser.expandedGroupIDs.contains(entry.id) ? "Collapse" : "Expand \(entry.tasks.count) Sessions") {
            if browser.expandedGroupIDs.contains(entry.id) {
                browser.expandedGroupIDs.remove(entry.id)
            } else {
                browser.expandedGroupIDs.insert(entry.id)
            }
        }
        Divider()
        Button("Merge Into One Task") {
            browser.merge(taskIDs: entry.tasks.map(\.id))
        }
        Menu("Project") {
            Button("None") { assign(entry, to: nil) }
            Divider()
            ForEach(browser.sidebarProjects) { summary in
                Button(ProjectName.display(summary.workstream.displayName)) {
                    assign(entry, to: summary.workstream.id)
                }
            }
        }
        .disabled(browser.sidebarProjects.isEmpty)
    }

    private func assign(_ entry: TimelineGroup, to workstreamID: String?) {
        browser.assign(taskIDs: entry.tasks.map(\.id), toWorkstream: workstreamID)
    }

    @ViewBuilder
    private func menu(for task: TaskMemory) -> some View {
        Button(task.isPinned ? "Unpin" : "Pin") { browser.togglePin(taskID: task.id) }
        Button("Rename") {
            browser.selectedTaskIDs = [task.id]
            browser.selectionDidChange()
            browser.renameRequestID = task.id
        }
        Menu("Project") {
            Button("None") { browser.assign(taskIDs: [task.id], toWorkstream: nil) }
            Divider()
            ForEach(browser.sidebarProjects) { summary in
                Button(ProjectName.display(summary.workstream.displayName)) {
                    browser.assign(taskIDs: [task.id], toWorkstream: summary.workstream.id)
                }
            }
        }
        .disabled(browser.sidebarProjects.isEmpty)
        Divider()
        Button("Merge \(browser.selectedTaskIDs.count) Tasks") { browser.mergeSelected() }
            .disabled(browser.selectedTaskIDs.count < 2 || !browser.selectedTaskIDs.contains(task.id))
        Divider()
        Button("Delete…", role: .destructive) { browser.pendingDeleteID = task.id }
    }

    private func clearFilters() {
        browser.searchText = ""
        browser.searchScope = .all
        browser.applicationFilter = nil
        browser.sidebarSelection = .recent
    }

    private var title: String {
        switch browser.sidebarSelection {
        case .recent: "Recent"
        case .today: "Today"
        case .pinned: "Pinned"
        case .patterns: "Patterns"
        case .skills: "Skills"
        case let .workstream(id): browser.workstream(id: id)?.displayName ?? "Project"
        }
    }

    private var subtitle: String {
        if browser.sidebarSelection == .patterns {
            return "\(model.workflowPatterns.count) statistically supported"
        }
        if browser.sidebarSelection == .skills {
            return "\(model.personalSkills.count) candidates and approved skills"
        }
        let count = browser.displayedTasks.count
        let noun = count == 1 ? "session" : "sessions"
        if browser.isFiltering, !browser.searchText.isEmpty {
            return "\(count) matching \(noun)"
        }
        // When episodes were rolled up, say so — otherwise the count reads as a
        // contradiction of the number of rows on screen.
        let entries = browser.days.reduce(0) { $0 + $1.entries.count } + (browser.nowTask == nil ? 0 : 1)
        guard entries > 0, entries < count else { return "\(count) \(noun)" }
        return "\(entries) grouped from \(count) \(noun)"
    }
}
