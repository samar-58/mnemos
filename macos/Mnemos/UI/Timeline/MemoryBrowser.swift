import Foundation

/// What the sidebar is pointing at. Drives the query that fills the task list.
enum SidebarItem: Hashable, Identifiable {
    case recent
    case today
    case pinned
    case workstream(String)

    var id: String {
        switch self {
        case .recent: "library.recent"
        case .today: "library.today"
        case .pinned: "library.pinned"
        case let .workstream(id): "workstream.\(id)"
        }
    }

    var isLibrary: Bool {
        if case .workstream = self { return false }
        return true
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

/// One day of tasks in the list.
struct TaskDay: Identifiable {
    let id: Date
    let label: String
    let tasks: [TaskMemory]
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
    private var searchDebounce: Task<Void, Never>?
    private static let pageSize = 50

    init(store: ContextEngineStore) {
        self.store = store
    }

    // MARK: - Derived state

    /// True when anything narrows the list: a query, a scope, an application
    /// filter, or a sidebar selection other than Recent.
    var isFiltering: Bool {
        !trimmedQuery.isEmpty
            || searchScope != .all
            || applicationFilter != nil
            || sidebarSelection != .recent
    }

    var displayedTasks: [TaskMemory] {
        isFiltering ? searchResults.map(\.task) : recentTasks
    }

    /// Tasks grouped into day sections, newest first.
    var days: [TaskDay] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [TaskMemory]] = [:]
        for task in displayedTasks {
            let day = calendar.startOfDay(for: task.endedAt)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(task)
        }
        return order.map { TaskDay(id: $0, label: DayHeading.label(for: $0), tasks: buckets[$0] ?? []) }
    }

    /// Every application seen in the current list, for the filter menu.
    var availableApplications: [String] {
        Set(displayedTasks.flatMap(\.applications)).sorted()
    }

    var selectedTasks: [TaskMemory] {
        displayedTasks.filter { selectedTaskIDs.contains($0.id) }
    }

    func result(for taskID: String) -> ContextSearchResult? {
        searchResults.first { $0.id == taskID }
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

    func selectionDidChange() {
        selectedSpanIDs = []
        guard selectedTaskIDs.count == 1,
              let id = selectedTaskIDs.first,
              let task = displayedTasks.first(where: { $0.id == id }) else {
            selectedTask = nil
            selectedTaskSpans = []
            selectedTaskEvidence = []
            return
        }
        loadDetail(for: task)
    }

    private func loadDetail(for task: TaskMemory) {
        selectedTask = task
        selectedTaskSpans = []
        selectedTaskEvidence = []
        Task { [weak self] in
            guard let self else { return }
            do {
                async let spans = store.spans(for: task.id)
                async let evidence = store.evidence(for: task.id)
                let loadedSpans = try await spans
                let loadedEvidence = try await evidence
                guard selectedTask?.id == task.id else { return }
                selectedTaskSpans = loadedSpans
                selectedTaskEvidence = loadedEvidence
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Reveals a task coming from outside the list — the menu bar or the recall
    /// panel — clearing filters if it is not currently visible.
    func reveal(taskID: String) {
        if displayedTasks.contains(where: { $0.id == taskID }) {
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
        let ids = Array(selectedTaskIDs)
        guard ids.count >= 2 else { return }
        mutate { try await $0.mergeTasks(ids) }
    }

    func splitSelectedSpans() {
        let ids = Array(selectedSpanIDs)
        guard !ids.isEmpty else { return }
        selectedSpanIDs = []
        mutate { _ = try await $0.moveSpans(ids, to: nil) }
    }

    func moveSelectedSpans(to taskID: String) {
        let ids = Array(selectedSpanIDs)
        guard !ids.isEmpty else { return }
        selectedSpanIDs = []
        mutate { _ = try await $0.moveSpans(ids, to: taskID) }
    }

    func assignSelectedTask(toWorkstream workstreamID: String?) {
        guard let id = selectedTask?.id else { return }
        mutate { try await $0.assignTask(id, toWorkstream: workstreamID) }
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
    /// current selection or scroll position more than necessary.
    func activityDidPersist() {
        Task { [weak self] in
            guard let self else { return }
            health = await store.health()
            do {
                sessions = try await store.recentSessions()
                let page = try await store.tasks(before: nil, limit: Self.pageSize)
                if !isFiltering { recentTasks = merge(page, into: recentTasks) }
                workstreams = try await store.workstreamSummaries()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Keeps already-loaded older pages while refreshing the newest page.
    private func merge(_ page: [TaskMemory], into existing: [TaskMemory]) -> [TaskMemory] {
        guard let oldest = page.last?.endedAt else { return existing }
        let tail = existing.filter { $0.endedAt < oldest }
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
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
