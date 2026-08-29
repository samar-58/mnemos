import Foundation

/// What the sidebar is pointing at. Drives the query that fills the task list.
enum SidebarItem: Hashable, Identifiable {
    case recent
    case today
    case pinned
    case patterns
    case skills
    case workstream(String)

    var id: String {
        switch self {
        case .recent: "library.recent"
        case .today: "library.today"
        case .pinned: "library.pinned"
        case .patterns: "intelligence.patterns"
        case .skills: "intelligence.skills"
        case let .workstream(id): "workstream.\(id)"
        }
    }

    var isLibrary: Bool {
        switch self {
        case .workstream: false
        default: true
        }
    }
}

/// Time window for the search field, exposed as search scopes.
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case today = "Today"
    case week = "Week"
    case month = "Month"

    var id: Self { self }

    func start(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .all: nil
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        }
    }
}

/// One day of the timeline, already grouped into the entries the list renders.
struct TaskDay: Identifiable {
    let id: Date
    let label: String
    let entries: [TimelineGroup]

    var tasks: [TaskMemory] { entries.flatMap(\.tasks) }

    /// Total time recorded that day, used in the day heading.
    var activeSeconds: TimeInterval { entries.reduce(0) { $0 + $1.activeSeconds } }
}

/// Owns everything the memory UI browses: the current sidebar selection, the
/// search query, the resulting tasks, and the selected task's detail. Capture,
/// permissions, and agent access stay in `AppModel`.
@MainActor
final class MemoryBrowser: ObservableObject {
    @Published var sidebarSelection: SidebarItem = .recent {
        didSet { if sidebarSelection != oldValue { applyFilters() } }
    }
    @Published var searchText = ""
    @Published var searchScope: SearchScope = .all {
        didSet { if searchScope != oldValue { applyFilters() } }
    }
    @Published var applicationFilter: String? {
        didSet { if applicationFilter != oldValue { applyFilters() } }
    }
    @Published var selectedTaskIDs: Set<String> = []
    @Published var selectedSpanIDs: Set<String> = []
    /// Timeline groups the user has opened. Collapsed is the default — the
    /// point of the roll-up is that a day reads as a handful of projects rather
    /// than as every episode the segmenter happened to cut.
    @Published var expandedGroupIDs: Set<String> = []
    /// The rolled-up group the detail pane is showing, if any.
    ///
    /// This is deliberately kept out of `selectedTaskIDs`: a collapsed group's
    /// episodes have no rows in the list, and a `List` selection made of ids it
    /// cannot see is not something to rely on. Exactly one of these two is
    /// active at a time.
    @Published private(set) var selectedGroupID: String?
    /// Selection inside the Patterns and Skills lists. These stay separate from
    /// task selection so switching sections never carries a stale detail view.
    @Published var selectedPatternID: String?
    @Published var selectedSkillID: String?
    /// Set when the user asks to rename from a menu, so the detail view can put
    /// the caret in the title field.
    @Published var renameRequestID: String?
    /// Set when a delete is requested from a menu; the task list owns the
    /// confirmation so every delete is confirmed the same way.
    @Published var pendingDeleteID: String?

    @Published private(set) var sessions: [WorkSession] = []
    @Published private(set) var recentTasks: [TaskMemory] = []
    @Published private(set) var workstreams: [WorkstreamSummary] = []
    @Published private(set) var searchResults: [ContextSearchResult] = []
    @Published private(set) var selectedTask: TaskMemory?
    @Published private(set) var selectedTaskSpans: [ActivitySpan] = []
    @Published private(set) var selectedTaskEvidence: [EvidenceItem] = []
    /// Spans for every task in a multi-episode selection, keyed by task id, so
    /// the group view can show each episode's activity without reloading as the
    /// user opens them.
    @Published private(set) var selectedGroupSpans: [String: [ActivitySpan]] = [:]
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var error: String?
    @Published private(set) var health = ContextStoreHealth(
        state: .indexing,
        observationCount: 0,
        sessionCount: 0,
        taskCount: 0,
        spanCount: 0,
        evidenceCount: 0,
        semanticVectorCount: 0,
        detail: "Preparing your memory…"
    )
    @Published private(set) var storage = ContextStorageUsage(
        databaseBytes: 0,
        rawRetentionDays: 30,
        redactionPolicyVersion: CapturePrivacy.redactionPolicyVersion,
        semanticSearchEnabled: true
    )

    private let store: ContextEngineStore
    private var searchGeneration = 0
    /// Guards detail loads against each other, so a slow group load never
    /// overwrites the selection that replaced it.
    private var detailGeneration = 0
    private var hasAutoSelected = false
    private var searchDebounce: Task<Void, Never>?
    private static let pageSize = 50

    init(store: ContextEngineStore) {
        self.store = store
    }

    // MARK: - Derived state

    /// True when anything narrows the list: a query, a scope, an application
    /// filter, or a sidebar selection other than Recent.
    var isFiltering: Bool {
        guard sidebarSelection != .patterns, sidebarSelection != .skills else { return false }
        return !trimmedQuery.isEmpty
            || searchScope != .all
            || applicationFilter != nil
            || sidebarSelection != .recent
    }

    var displayedTasks: [TaskMemory] {
        isFiltering ? searchResults.map(\.task) : recentTasks
    }

    /// The task being recorded into right now, shown on its own above the day
    /// sections. Filtered views keep it inline instead, so a search never hides
    /// a matching task behind a "Now" heading.
    var nowTask: TaskMemory? {
        isFiltering ? nil : displayedTasks.first(where: \.isOpen)
    }

    /// Tasks grouped into day sections, newest first, with each day's episodes
    /// rolled up per project. Excludes `nowTask`, which the list renders
    /// separately. A search shows every match on its own line instead, because
    /// hiding a hit inside a collapsed group makes the result look missing.
    var days: [TaskDay] {
        let calendar = Calendar.current
        let nowID = nowTask?.id
        let rollUp = trimmedQuery.isEmpty
        var order: [Date] = []
        var buckets: [Date: [TaskMemory]] = [:]
        for task in displayedTasks where task.id != nowID {
            let day = calendar.startOfDay(for: task.endedAt)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(task)
        }
        return order.map { day in
            let tasks = buckets[day] ?? []
            let entries = rollUp
                ? TimelineGroup.group(tasks)
                : tasks.map { TimelineGroup(tasks: [$0], workstreamID: $0.workstream?.id) }
            return TaskDay(id: day, label: DayHeading.label(for: day), entries: entries)
        }
    }

    /// The entry a task id belongs to, so the list can keep a group expanded
    /// when one of its episodes is revealed from elsewhere.
    func group(containing taskID: String) -> TimelineGroup? {
        days.lazy.flatMap(\.entries).first { $0.taskIDs.contains(taskID) }
    }

    /// Every application seen in the current list, for the filter menu.
    var availableApplications: [String] {
        Set(displayedTasks.flatMap(\.applications)).sorted()
    }

    /// Projects worth a sidebar row, most recently worked on first.
    ///
    /// Anchors are derived from paths and URLs, which produces a long tail of
    /// fragments — a bare `https:`, a mail message id, a numeric path segment.
    /// Those still group their tasks in the store; they just do not belong in a
    /// list a person is meant to navigate by. Case-only duplicates collapse to
    /// the busier of the two.
    var sidebarProjects: [WorkstreamSummary] {
        var byName: [String: WorkstreamSummary] = [:]
        for summary in workstreams where summary.taskCount > 0 {
            guard ProjectName.isMeaningful(summary.workstream.displayName) else { continue }
            let key = ProjectName.display(summary.workstream.displayName).lowercased()
            if let existing = byName[key], existing.taskCount >= summary.taskCount { continue }
            byName[key] = summary
        }
        return byName.values.sorted { left, right in
            switch (left.lastActivityAt, right.lastActivityAt) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.taskCount > right.taskCount
            }
        }
    }

    /// Projects hidden from the sidebar because their derived name carries no
    /// information. Surfaced as a count so the list never silently lies about
    /// how much it is showing.
    var hiddenProjectCount: Int {
        workstreams.filter { $0.taskCount > 0 }.count - sidebarProjects.count
    }

    var selectedTasks: [TaskMemory] {
        displayedTasks.filter { selectedTaskIDs.contains($0.id) }
    }

    func result(for taskID: String) -> ContextSearchResult? {
        searchResults.first { $0.id == taskID }
    }

    /// The selected task's activity with consecutive look-alike spans folded
    /// together, which is what the detail view lists.
    var selectedTaskSteps: [ActivityStep] {
        ActivityStep.collapse(selectedTaskSpans)
    }

    /// Spans behind the current activity selection. A row stands for a whole
    /// step, so splitting or moving has to act on every span in it — otherwise
    /// a step that reads "×3" would only move a third of itself.
    private var resolvedSpanIDs: [String] {
        let steps = selectedTaskSteps
        guard !steps.isEmpty else { return Array(selectedSpanIDs) }
        var ids: [String] = []
        for step in steps where selectedSpanIDs.contains(step.id) {
            ids.append(contentsOf: step.spanIDs)
        }
        // Anything selected that is not a step leader — a stale id, or a
        // selection made before the spans reloaded — still gets carried through.
        let known = Set(steps.map(\.id))
        ids.append(contentsOf: selectedSpanIDs.filter { !known.contains($0) })
        return Array(Set(ids))
    }

    func workstream(id: String) -> Workstream? {
        workstreams.first { $0.workstream.id == id }?.workstream
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Loading

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.prepare()
                async let sessions = store.recentSessions()
                async let tasks = store.tasks(before: nil, limit: Self.pageSize)
                async let workstreams = store.workstreamSummaries()
                self.sessions = try await sessions
                self.recentTasks = try await tasks
                self.workstreams = try await workstreams
                reachedEnd = self.recentTasks.count < Self.pageSize
                health = await store.health()
                storage = await store.storageUsage()
                error = nil
                if let selectedTask, let refreshed = self.recentTasks.first(where: { $0.id == selectedTask.id }) {
                    self.selectedTask = refreshed
                }
                if isFiltering { applyFilters() }
                selectFirstIfNothingChosen()
            } catch {
                health = await store.health()
                self.error = error.localizedDescription
            }
        }
    }

    /// Appends the next page of recent tasks. Only meaningful when unfiltered —
    /// filtered results come back from the store already capped.
    func loadMore() {
        guard !isFiltering, !isLoadingMore, !reachedEnd, let oldest = recentTasks.last?.endedAt else { return }
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingMore = false }
            do {
                let page = try await store.tasks(before: oldest, limit: Self.pageSize)
                let known = Set(recentTasks.map(\.id))
                recentTasks.append(contentsOf: page.filter { !known.contains($0.id) })
                reachedEnd = page.count < Self.pageSize
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Debounced entry point for the search field.
    func searchTextDidChange() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    func applyFilters() {
        // A group belongs to the list that produced it; changing what the list
        // shows retires it rather than leaving the detail pane on a group the
        // user can no longer see.
        selectedGroupID = nil
        guard sidebarSelection != .patterns, sidebarSelection != .skills else {
            searchResults = []
            isSearching = false
            selectedTaskIDs = []
            if sidebarSelection != .patterns { selectedPatternID = nil }
            if sidebarSelection != .skills { selectedSkillID = nil }
            selectionDidChange()
            return
        }
        selectedPatternID = nil
        selectedSkillID = nil
        searchGeneration += 1
        let generation = searchGeneration

        guard isFiltering else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let query = currentQuery()
        Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await store.search(query)
                guard generation == searchGeneration else { return }
                searchResults = results
                error = nil
                isSearching = false
            } catch {
                guard generation == searchGeneration else { return }
                searchResults = []
                self.error = error.localizedDescription
                isSearching = false
            }
        }
    }

    private func currentQuery() -> MemoryQuery {
        var from = searchScope.start()
        var pinnedOnly = false
        var workstreamKey: String?

        switch sidebarSelection {
        case .recent:
            break
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: .now)
            from = max(from ?? startOfDay, startOfDay)
        case .pinned:
            pinnedOnly = true
        case .patterns, .skills:
            break
        case let .workstream(id):
            workstreamKey = workstream(id: id)?.canonicalKey
        }

        return MemoryQuery(
            text: trimmedQuery.isEmpty ? nil : trimmedQuery,
            from: from,
            to: nil,
            application: applicationFilter,
            workstream: workstreamKey,
            pinnedOnly: pinnedOnly,
            limit: 50
        )
    }

    /// A one-shot search that does not disturb the browsing state, for the
    /// recall panel and the menu bar.
    func quickSearch(_ text: String, limit: Int = 8) async -> [ContextSearchResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try await store.search(
                MemoryQuery(
                    text: trimmed,
                    from: nil,
                    to: nil,
                    application: nil,
                    workstream: nil,
                    limit: limit
                )
            )
        } catch {
            return []
        }
    }

    // MARK: - Selection

    /// Called whenever the list's own selection changes. An empty selection
    /// while a group is open is the state `selectGroup` deliberately puts the
    /// browser in, so it is left alone.
    func selectionDidChange() {
        selectedSpanIDs = []
        let tasks = selectedTasks
        guard !tasks.isEmpty else {
            if selectedGroupID == nil { clearDetail() }
            return
        }
        selectedGroupID = nil
        if tasks.count == 1 {
            loadDetail(for: tasks[0])
        } else {
            loadDetail(forGroup: tasks)
        }
    }

    /// Opens the newest thing in the list the first time there is anything to
    /// open, so the window does not present three columns with an empty pane in
    /// the largest one. Only ever fires once: after that, an empty selection is
    /// something the user chose.
    private func selectFirstIfNothingChosen() {
        guard !hasAutoSelected, selectedTaskIDs.isEmpty, selectedGroupID == nil else { return }
        if let now = nowTask {
            hasAutoSelected = true
            selectedTaskIDs = [now.id]
            selectionDidChange()
            return
        }
        guard let first = days.first?.entries.first else { return }
        hasAutoSelected = true
        if first.isGroup {
            selectGroup(first)
        } else {
            selectedTaskIDs = [first.lead.id]
            selectionDidChange()
        }
    }

    /// Opens a rolled-up group in the detail pane.
    func selectGroup(_ group: TimelineGroup) {
        selectedGroupID = group.id
        selectedTaskIDs = []
        selectedSpanIDs = []
        loadDetail(forGroup: group.tasks)
    }

    /// The group currently open, resolved against the list as it stands now so
    /// it keeps up with new activity landing in the same project.
    var selectedGroup: TimelineGroup? {
        guard let selectedGroupID else { return nil }
        return days.lazy.flatMap(\.entries).first { $0.id == selectedGroupID }
    }

    /// The tasks the detail pane is acting on, whichever selection is active.
    var focusedTasks: [TaskMemory] {
        if let selectedGroup { return selectedGroup.tasks }
        return selectedTasks
    }

    private func clearDetail() {
        selectedTask = nil
        selectedTaskSpans = []
        selectedTaskEvidence = []
        selectedGroupSpans = [:]
        selectedGroupID = nil
    }

    private func loadDetail(for task: TaskMemory) {
        selectedTask = task
        selectedTaskSpans = []
        selectedTaskEvidence = []
        selectedGroupSpans = [:]
        detailGeneration += 1
        let generation = detailGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                async let spans = store.spans(for: task.id)
                async let evidence = store.evidence(for: task.id)
                let loadedSpans = try await spans
                let loadedEvidence = try await evidence
                guard generation == detailGeneration, selectedTask?.id == task.id else { return }
                selectedTaskSpans = loadedSpans
                selectedTaskEvidence = loadedEvidence
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Loads the activity behind a whole timeline group. Evidence is pooled
    /// across the episodes so "Copy context" and the sources inspector describe
    /// the group the user is actually looking at.
    private func loadDetail(forGroup tasks: [TaskMemory]) {
        selectedTask = nil
        selectedTaskSpans = []
        selectedTaskEvidence = []
        selectedGroupSpans = [:]
        let ids = tasks.map(\.id)
        detailGeneration += 1
        let generation = detailGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                var spansByTask: [String: [ActivitySpan]] = [:]
                var evidence: [EvidenceItem] = []
                for id in ids {
                    async let spans = store.spans(for: id)
                    async let items = store.evidence(for: id)
                    spansByTask[id] = try await spans
                    evidence.append(contentsOf: try await items)
                }
                guard generation == detailGeneration else { return }
                selectedGroupSpans = spansByTask
                selectedTaskEvidence = evidence.sorted { $0.timestamp > $1.timestamp }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Surfaces a failure from capture recording directly in the list, instead
    /// of leaving it buried in Settings ▸ Advanced ▸ Diagnostics where it reads
    /// exactly like the list simply being stale.
    func recordingFailed(_ message: String) {
        error = message
    }

    /// Clears a recording failure once activity is persisting again. Most
    /// write failures — a momentarily busy database under a burst of writes,
    /// for instance — are transient, so a banner that never clears would
    /// misreport a recovered app as still broken.
    func recordingRecovered() {
        error = nil
    }

    /// Reveals a task coming from outside the list — the menu bar or the recall
    /// panel — clearing filters if it is not currently visible.
    func reveal(taskID: String) {
        if displayedTasks.contains(where: { $0.id == taskID }) {
            if let group = group(containing: taskID) { expandedGroupIDs.insert(group.id) }
            selectedTaskIDs = [taskID]
            selectionDidChange()
            return
        }
        searchText = ""
        searchScope = .all
        applicationFilter = nil
        sidebarSelection = .recent
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let task = try await store.task(id: taskID) else { return }
                if !recentTasks.contains(where: { $0.id == taskID }) {
                    recentTasks.insert(task, at: 0)
                }
                selectedTaskIDs = [taskID]
                loadDetail(for: task)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Corrections

    func rename(_ title: String, taskID: String? = nil) {
        guard let id = taskID ?? selectedTask?.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedTask?.title else { return }
        mutate { try await $0.renameTask(id: id, title: trimmed) }
    }

    func togglePin(taskID: String? = nil) {
        guard let task = taskID.flatMap({ id in displayedTasks.first { $0.id == id } }) ?? selectedTask else { return }
        mutate { try await $0.setPinned(!task.isPinned, taskID: task.id) }
    }

    func delete(taskID: String? = nil) {
        guard let id = taskID ?? selectedTask?.id else { return }
        selectedTaskIDs.remove(id)
        selectedTask = nil
        selectedTaskSpans = []
        selectedTaskEvidence = []
        mutate { try await $0.deleteTask(id: id) }
    }

    func mergeSelected() {
        merge(taskIDs: focusedTasks.map(\.id))
    }

    /// Merges an explicit set of episodes, so a rolled-up group can be made
    /// permanent without first having to select its rows.
    func merge(taskIDs: [String]) {
        guard taskIDs.count >= 2 else { return }
        // The group about to disappear must not stay selected, or the detail
        // pane would keep pointing at ids the merge has already consumed.
        selectedGroupID = nil
        selectedTaskIDs = []
        mutate { try await $0.mergeTasks(taskIDs) }
    }

    func splitSelectedSpans() {
        let ids = resolvedSpanIDs
        guard !ids.isEmpty else { return }
        selectedSpanIDs = []
        mutate { _ = try await $0.moveSpans(ids, to: nil) }
    }

    func moveSelectedSpans(to taskID: String) {
        let ids = resolvedSpanIDs
        guard !ids.isEmpty else { return }
        selectedSpanIDs = []
        mutate { _ = try await $0.moveSpans(ids, to: taskID) }
    }

    func assignSelectedTask(toWorkstream workstreamID: String?) {
        guard let id = selectedTask?.id else { return }
        mutate { try await $0.assignTask(id, toWorkstream: workstreamID) }
    }

    /// Reassigns several tasks in one pass, so moving a whole timeline group to
    /// another project costs one refresh rather than one per episode.
    func assign(taskIDs: [String], toWorkstream workstreamID: String?) {
        guard !taskIDs.isEmpty else { return }
        mutate { store in
            for id in taskIDs { try await store.assignTask(id, toWorkstream: workstreamID) }
        }
    }

    // MARK: - Storage settings

    func setSemanticSearchEnabled(_ enabled: Bool) {
        mutate { try await $0.setSemanticSearchEnabled(enabled) }
    }

    func setRawRetentionDays(_ days: Int?) {
        mutate { try await $0.setRawRetentionDays(days) }
    }

    func rebuildSemanticIndex() {
        mutate { try await $0.rebuildSemanticIndex() }
    }

    func redactionPolicyDidChange() {
        mutate { try await $0.redactionPolicyDidChange() }
    }

    /// Refreshes counts after new activity is persisted, without disturbing the
    /// current selection or scroll position more than necessary. Whatever the
    /// list is currently showing — the unfiltered Recent page or a filtered
    /// view (Today, Pinned, a workstream, a search) — gets a fresh look,
    /// otherwise newly captured activity never reaches a filtered view.
    func activityDidPersist() {
        Task { [weak self] in
            guard let self else { return }
            health = await store.health()
            do {
                sessions = try await store.recentSessions()
                workstreams = try await store.workstreamSummaries()
                if isFiltering {
                    applyFilters()
                } else {
                    let page = try await store.tasks(before: nil, limit: Self.pageSize)
                    recentTasks = merge(page, into: recentTasks)
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Keeps already-loaded older pages while refreshing the newest page. Tasks
    /// that reappear in the fresh page (their `endedAt` moved forward because
    /// they are still open) are deduplicated by id rather than by timestamp, so
    /// an older snapshot of the same task never lingers alongside its update.
    private func merge(_ page: [TaskMemory], into existing: [TaskMemory]) -> [TaskMemory] {
        guard let oldest = page.last?.endedAt else { return existing }
        let freshIDs = Set(page.map(\.id))
        let tail = existing.filter { !freshIDs.contains($0.id) && $0.endedAt < oldest }
        return page + tail
    }

    private func mutate(_ operation: @escaping (ContextEngineStore) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(store)
                refresh()
                if let id = selectedTask?.id, let refreshed = try await store.task(id: id) {
                    loadDetail(for: refreshed)
                } else if let group = selectedGroup {
                    loadDetail(forGroup: group.tasks)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
