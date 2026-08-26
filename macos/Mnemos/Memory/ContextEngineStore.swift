import Foundation
import SQLite3

private enum ContextStoreError: LocalizedError {
    case unavailable(String)
    case sqlite(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .sqlite(message), let .invalid(message): message
        }
    }
}

actor ContextEngineStore {
    private struct Observation {
        let id: String
        let timestamp: Date
        let kind: String
        let applicationName: String
        let bundleID: String
        let windowTitle: String?
        let documentPath: String?
        let url: String?
        let target: String?
        let detail: String?
        let axText: String?
    }

    private struct Anchor {
        let kind: WorkstreamKind
        let canonicalKey: String
        let displayName: String
        let values: [(kind: String, value: String, strength: Double)]
    }

    private struct OpenSession {
        let id: String
        let lastObservationAt: Date
    }

    private struct OpenSpan {
        let id: String
        let taskID: String
        let bundleID: String
        let windowTitle: String?
        let anchorKey: String?
        let lastObservationAt: Date
    }

    private struct EvidenceCandidate {
        let id: String
        let excerpt: String
        let application: String
        let kind: String
        let priority: Int
        let userSelected: Bool
        let timestamp: Date
    }

    private enum SQLValue {
        case text(String)
        case int(Int)
        case double(Double)
        case blob(Data)
    }

    private var database: OpaquePointer?
    private let databaseURL: URL
    private let embeddingProvider = AppleSentenceEmbeddingProvider()
    private var anchorCache: [String: Anchor] = [:]
    private var derivationTasks: [String: Task<Void, Never>] = [:]
    private var derivationTokens: [String: UUID] = [:]
    private var semanticIndexIssue: String?

    private static let rawRetentionDefaultsKey = "rawRetentionDaysV2"
    private static let semanticSearchDefaultsKey = "semanticSearchEnabledV2"
    private static let sessionIdleSeconds: TimeInterval = 15 * 60
    private static let spanIdleSeconds: TimeInterval = 60
    private static let taskCandidateSeconds: TimeInterval = 30 * 60
    private static let semanticContinuitySeconds: TimeInterval = 2 * 60
    private static let maximumTaskCandidates = 8
    private static let maximumEvidenceItems = 24
    private static let algorithmVersion = 5

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
            if UserDefaults.standard.object(forKey: Self.semanticSearchDefaultsKey) == nil {
                UserDefaults.standard.set(true, forKey: Self.semanticSearchDefaultsKey)
            }
            return
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mnemos", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("mnemos.sqlite", isDirectory: false)
        if UserDefaults.standard.object(forKey: Self.semanticSearchDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.semanticSearchDefaultsKey)
        }
    }

    func shutdownForTesting() {
        for task in derivationTasks.values { task.cancel() }
        derivationTasks.removeAll()
        derivationTokens.removeAll()
        if let database { sqlite3_close(database) }
        database = nil
    }

    func prepare() throws {
        try prepareIfNeeded()
    }

    func record(_ event: CapturedEvent) throws {
        guard let event = CapturePrivacy.sanitizedEvent(event) else { return }
        try prepareIfNeeded()
        let observation = Observation(
            id: event.id.uuidString.lowercased(),
            timestamp: event.timestamp,
            kind: event.kind.rawValue,
            applicationName: event.applicationName,
            bundleID: event.bundleID,
            windowTitle: event.windowTitle,
            documentPath: event.documentPath,
            url: event.url,
            target: event.target?.summary,
            detail: event.detail,
            axText: event.axText
        )

        try execute("BEGIN IMMEDIATE TRANSACTION")
        let taskID: String
        do {
            taskID = try derive(observation)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        applyPrivateFilePermissions()
        let taskIsOpen = (try? scalarInt(
            "SELECT is_open FROM task_episodes_v2 WHERE id = ?",
            values: [.text(taskID)]
        )) == 1
        if taskIsOpen {
            enqueueDerivation(taskID, delayMilliseconds: 30_000)
        } else {
            let closedTaskIDs = (try? stringColumn(
                "SELECT id FROM task_episodes_v2 WHERE session_id = (SELECT session_id FROM task_episodes_v2 WHERE id = ?)",
                values: [.text(taskID)]
            )) ?? [taskID]
            for id in closedTaskIDs { enqueueDerivation(id, delayMilliseconds: 0) }
        }
    }

    func health() -> ContextStoreHealth {
        do {
            try prepareIfNeeded()
            let taskCount = try scalarInt("SELECT COUNT(*) FROM task_episodes_v2")
            let vectorCount = try scalarInt("SELECT COUNT(*) FROM episode_embeddings")
            let derivationComplete = try scalarText("SELECT status FROM derivation_state WHERE id = 1") == "complete"
            let semanticComplete = !semanticSearchEnabled || taskCount == 0 || vectorCount == taskCount
                || semanticIndexIssue != nil
            let state: ContextStoreHealth.State = derivationComplete && semanticComplete ? .ready : .indexing
            return ContextStoreHealth(
                state: state,
                observationCount: try scalarInt("SELECT COUNT(*) FROM observations"),
                sessionCount: try scalarInt("SELECT COUNT(*) FROM work_sessions"),
                taskCount: taskCount,
                spanCount: try scalarInt("SELECT COUNT(*) FROM activity_spans"),
                evidenceCount: try scalarInt("SELECT COUNT(*) FROM evidence_items"),
                semanticVectorCount: vectorCount,
                detail: semanticIndexIssue
                    ?? (state == .ready ? "V2 context index is ready." : "Building the V2 context index…")
            )
        } catch {
            return ContextStoreHealth(
                state: .unavailable,
                observationCount: 0,
                sessionCount: 0,
                taskCount: 0,
                spanCount: 0,
                evidenceCount: 0,
                semanticVectorCount: 0,
                detail: error.localizedDescription
            )
        }
    }

    func storageUsage() -> ContextStorageUsage {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return ContextStorageUsage(
            databaseBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            rawRetentionDays: rawRetentionDays,
            redactionPolicyVersion: CapturePrivacy.redactionPolicyVersion,
            semanticSearchEnabled: semanticSearchEnabled
        )
    }

    var semanticSearchEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.semanticSearchDefaultsKey)
    }

    var rawRetentionDays: Int? {
        let stored = UserDefaults.standard.integer(forKey: Self.rawRetentionDefaultsKey)
        if stored == -1 { return nil }
        return [7, 30, 90].contains(stored) ? stored : 30
    }

    func setSemanticSearchEnabled(_ enabled: Bool) throws {
        try prepareIfNeeded()
        UserDefaults.standard.set(enabled, forKey: Self.semanticSearchDefaultsKey)
        if !enabled {
            try execute("DELETE FROM episode_embeddings")
        } else {
            for id in try stringColumn("SELECT id FROM task_episodes_v2") { enqueueDerivation(id) }
        }
    }

    func setRawRetentionDays(_ days: Int?) throws {
        guard days == nil || [7, 30, 90].contains(days!) else {
            throw ContextStoreError.invalid("Retention must be 7, 30, 90 days, or forever.")
        }
        UserDefaults.standard.set(days ?? -1, forKey: Self.rawRetentionDefaultsKey)
        try prepareIfNeeded()
        try pruneExpiredObservations(now: .now)
    }

    func rebuildSemanticIndex() throws {
        try prepareIfNeeded()
        try execute("DELETE FROM episode_embeddings")
        for id in try stringColumn("SELECT id FROM task_episodes_v2") { enqueueDerivation(id) }
    }

    func redactionPolicyDidChange() throws {
        try prepareIfNeeded()
        var rows: [(String, String?, String?, String?, String?)] = []
        try withStatement("SELECT id, excerpt, url, document_path, target FROM evidence_items") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((
                    columnText(statement, 0) ?? "", columnText(statement, 1), columnText(statement, 2),
                    columnText(statement, 3), columnText(statement, 4)
                ))
            }
        }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for (id, excerpt, url, path, target) in rows {
                let sanitizedExcerpt = CapturePrivacy.sanitize(excerpt, maximumLength: 2_000, preserveLines: true)
                let sanitizedURL = CapturePrivacy.sanitizedBrowserURL(url)?.absoluteString
                let sanitizedPath = CapturePrivacy.sanitize(path, maximumLength: 1_000)
                let sanitizedTarget = CapturePrivacy.sanitize(target, maximumLength: 500)
                try withStatement(
                    "UPDATE evidence_items SET excerpt = ?, url = ?, document_path = ?, target = ?, redaction_policy_version = ? WHERE id = ?",
                    values: [
                        .text(sanitizedExcerpt ?? ""), .text(sanitizedURL ?? ""), .text(sanitizedPath ?? ""),
                        .text(sanitizedTarget ?? ""), .int(CapturePrivacy.redactionPolicyVersion), .text(id),
                    ]
                ) { statement in
                    for (index, value) in [(1, sanitizedExcerpt), (2, sanitizedURL), (3, sanitizedPath), (4, sanitizedTarget)] where value == nil {
                        sqlite3_bind_null(statement, Int32(index))
                    }
                    try stepDone(statement)
                }
            }
            try execute("DELETE FROM episode_embeddings")
            for id in try stringColumn("SELECT id FROM task_episodes_v2") { try reindexTask(id) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        for id in try stringColumn("SELECT id FROM task_episodes_v2") { enqueueDerivation(id) }
    }

    func recentSessions(limit: Int = 20) throws -> [WorkSession] {
        try prepareIfNeeded()
        var sessions: [WorkSession] = []
        try withStatement(
            """
            SELECT s.id, s.started_at, s.ended_at, s.is_open, COUNT(DISTINCT t.id),
                   COALESCE(GROUP_CONCAT(DISTINCT sp.application_name), '')
            FROM work_sessions s
            LEFT JOIN task_episodes_v2 t ON t.session_id = s.id
            LEFT JOIN activity_spans sp ON sp.session_id = s.id
            GROUP BY s.id
            ORDER BY s.ended_at DESC
            LIMIT ?
            """,
            values: [.int(min(max(limit, 1), 50))]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let applications = (columnText(statement, 5) ?? "")
                    .split(separator: ",").map(String.init).sorted()
                sessions.append(WorkSession(
                    id: columnText(statement, 0) ?? "unknown",
                    startedAt: dateColumn(statement, 1),
                    endedAt: dateColumn(statement, 2),
                    taskCount: Int(sqlite3_column_int64(statement, 4)),
                    applications: applications,
                    isOpen: sqlite3_column_int(statement, 3) != 0
                ))
            }
        }
        return sessions
    }

    func allWorkstreams() throws -> [Workstream] {
        try prepareIfNeeded()
        var workstreams: [Workstream] = []
        try withStatement(
            "SELECT id, kind, canonical_key, display_name, user_confirmed FROM workstreams ORDER BY display_name COLLATE NOCASE"
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                workstreams.append(decodeWorkstream(statement, offset: 0))
            }
        }
        return workstreams
    }

    /// Workstreams with their task counts and most recent activity, ordered by
    /// recency so the sidebar shows live work first. Workstreams that have lost
    /// all of their tasks sort last and report no activity.
    func workstreamSummaries() throws -> [WorkstreamSummary] {
        try prepareIfNeeded()
        var summaries: [WorkstreamSummary] = []
        try withStatement(
            """
            SELECT w.id, w.kind, w.canonical_key, w.display_name, w.user_confirmed,
                   COUNT(t.id), MAX(t.ended_at)
            FROM workstreams w
            LEFT JOIN task_episodes_v2 t ON t.workstream_id = w.id
            GROUP BY w.id
            ORDER BY MAX(t.ended_at) DESC, w.display_name COLLATE NOCASE
            """
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let count = Int(sqlite3_column_int64(statement, 5))
                summaries.append(WorkstreamSummary(
                    workstream: decodeWorkstream(statement, offset: 0),
                    taskCount: count,
                    lastActivityAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : dateColumn(statement, 6)
                ))
            }
        }
        return summaries
    }

    /// Page backwards through tasks by end time. Passing `before` continues from
    /// the oldest task already on screen.
    func tasks(before: Date? = nil, limit: Int = 50) throws -> [TaskMemory] {
        try prepareIfNeeded()
        let capped = min(max(limit, 1), 200)
        guard let before else {
            return try queryTasks(
                "\(taskSelectSQL) ORDER BY t.ended_at DESC LIMIT ?",
                values: [.int(capped)]
            )
        }
        return try queryTasks(
            "\(taskSelectSQL) WHERE t.ended_at < ? ORDER BY t.ended_at DESC LIMIT ?",
            values: [.double(before.timeIntervalSince1970), .int(capped)]
        )
    }

    func recentTasks(limit: Int = 30) throws -> [TaskMemory] {
        try prepareIfNeeded()
        return try queryTasks(
            """
            \(taskSelectSQL)
            ORDER BY t.ended_at DESC
            LIMIT ?
            """,
            values: [.int(min(max(limit, 1), 100))]
        )
    }

    func tasks(in sessionID: String) throws -> [TaskMemory] {
        try prepareIfNeeded()
        return try queryTasks(
            """
            \(taskSelectSQL)
            WHERE t.session_id = ?
            ORDER BY t.started_at
            """,
            values: [.text(sessionID)]
        )
    }

    func task(id: String) throws -> TaskMemory? {
        try prepareIfNeeded()
        return try queryTasks("\(taskSelectSQL) WHERE t.id = ? LIMIT 1", values: [.text(id)]).first
    }

    func spans(for taskID: String) throws -> [ActivitySpan] {
        try prepareIfNeeded()
        var spans: [ActivitySpan] = []
        try withStatement(
            """
            SELECT id, task_id, started_at, ended_at, application_name, bundle_id,
                   window_title, document_path, url, anchor_key, event_count
            FROM activity_spans WHERE task_id = ? ORDER BY started_at
            """,
            values: [.text(taskID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                spans.append(ActivitySpan(
                    id: columnText(statement, 0) ?? "unknown",
                    taskID: columnText(statement, 1) ?? taskID,
                    startedAt: dateColumn(statement, 2),
                    endedAt: dateColumn(statement, 3),
                    applicationName: columnText(statement, 4) ?? "Unknown",
                    bundleID: columnText(statement, 5) ?? "unknown",
                    windowTitle: columnText(statement, 6),
                    documentPath: columnText(statement, 7),
                    url: columnText(statement, 8),
                    anchorKey: columnText(statement, 9),
                    eventCount: Int(sqlite3_column_int64(statement, 10))
                ))
            }
        }
        return spans
    }

    func evidence(for taskID: String, limit: Int = 50, before: Date? = nil) throws -> [EvidenceItem] {
        try prepareIfNeeded()
        var sql = """
        SELECT id, task_id, observation_id, timestamp, kind, application_name, excerpt,
               url, document_path, target, source, priority, redaction_policy_version
        FROM evidence_items WHERE task_id = ?
        """
        var values: [SQLValue] = [.text(taskID)]
        if let before {
            sql += " AND timestamp < ?"
            values.append(.double(before.timeIntervalSince1970))
        }
        sql += " ORDER BY timestamp DESC LIMIT ?"
        values.append(.int(min(max(limit, 1), 200)))
        var items: [EvidenceItem] = []
        try withStatement(sql, values: values) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(decodeEvidence(statement))
            }
        }
        return items.reversed()
    }

    func context(for taskID: String, evidenceLimit: Int = 12) throws -> TaskContext? {
        try prepareIfNeeded()
        guard let task = try task(id: taskID) else { return nil }
        let neighbors = try queryTasks(
            """
            \(taskSelectSQL)
            WHERE t.session_id = ? AND t.id <> ?
            ORDER BY ABS(t.started_at - ?)
            LIMIT 8
            """,
            values: [.text(task.sessionID), .text(task.id), .double(task.startedAt.timeIntervalSince1970)]
        )
        let previous = neighbors.filter { $0.endedAt <= task.startedAt }.max(by: { $0.endedAt < $1.endedAt })
        let next = neighbors.filter { $0.startedAt >= task.endedAt }.min(by: { $0.startedAt < $1.startedAt })
        return TaskContext(
            task: task,
            spans: try spans(for: taskID),
            evidence: try evidence(for: taskID, limit: evidenceLimit),
            previousTask: previous,
            nextTask: next
        )
    }

    func timeline(from: Date, to: Date, limit: Int = 50) throws -> [TimelineEntry] {
        try prepareIfNeeded()
        let tasks = try queryTasks(
            """
            \(taskSelectSQL)
            WHERE t.ended_at >= ? AND t.started_at <= ?
            ORDER BY t.started_at
            LIMIT ?
            """,
            values: [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970), .int(min(max(limit, 1), 100))]
        )
        let sessions = Dictionary(uniqueKeysWithValues: try recentSessions(limit: 100).map { ($0.id, $0) })
        return tasks.compactMap { task in sessions[task.sessionID].map { TimelineEntry(task: task, session: $0) } }
    }

    func search(_ query: MemoryQuery) async throws -> [ContextSearchResult] {
        try prepareIfNeeded()
        let normalized = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized?.isEmpty != false {
            return try filteredRecentTasks(query).map {
                ContextSearchResult(
                    task: $0,
                    score: 0,
                    highlights: [],
                    matchReasons: ["time"],
                    evidencePreviews: try evidence(for: $0.id, limit: 3)
                )
            }
        }

        let text = normalized!
        var fused: [String: (score: Double, highlights: [String], reasons: Set<String>)] = [:]
        let filter = taskFilterSQL(query, alias: "t")
        if let match = Self.ftsQuery(from: text) {
            let sql = """
            SELECT t.id, snippet(task_v2_fts, 2, '‹', '›', '…', 28)
            FROM task_v2_fts
            JOIN task_episodes_v2 t ON t.id = task_v2_fts.task_id
            LEFT JOIN workstreams w ON w.id = t.workstream_id
            WHERE task_v2_fts MATCH ? \(filter.sql)
            ORDER BY bm25(task_v2_fts, 0.0, 4.0, 2.0, 1.5, 1.5, 1.0)
            LIMIT 100
            """
            var values: [SQLValue] = [.text(match)]
            values.append(contentsOf: filter.values)
            var rank = 0
            try withStatement(sql, values: values) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let id = columnText(statement, 0) else { continue }
                    let highlight = columnText(statement, 1).map { [$0] } ?? []
                    fused[id] = (1 / Double(61 + rank), highlight, ["lexical"])
                    rank += 1
                }
            }
        }

        if semanticSearchEnabled, let queryVector = await embeddingProvider.embed(text) {
            let sql = """
            SELECT e.task_id, e.vector
            FROM episode_embeddings e
            JOIN task_episodes_v2 t ON t.id = e.task_id
            LEFT JOIN workstreams w ON w.id = t.workstream_id
            WHERE e.provider = ? AND e.language = ? AND e.revision = ? AND e.dimension = ? \(filter.sql)
            """
            var values: [SQLValue] = [
                .text(queryVector.provider), .text(queryVector.language),
                .int(queryVector.revision), .int(queryVector.dimension),
            ]
            values.append(contentsOf: filter.values)
            var semantic: [(String, Float)] = []
            try withStatement(sql, values: values) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let id = columnText(statement, 0),
                          let data = columnData(statement, 1),
                          let vector = AppleSentenceEmbeddingProvider.decode(data, dimension: queryVector.dimension),
                          let score = AppleSentenceEmbeddingProvider.cosine(queryVector.values, vector) else { continue }
                    semantic.append((id, score))
                }
            }
            semantic.sort { $0.1 > $1.1 }
            for (rank, candidate) in semantic.prefix(100).enumerated() {
                if var existing = fused[candidate.0] {
                    existing.score += 1 / Double(61 + rank)
                    existing.reasons.insert("semantic")
                    fused[candidate.0] = existing
                } else {
                    fused[candidate.0] = (1 / Double(61 + rank), [], ["semantic"])
                }
            }
        }

        let ids = fused.keys.sorted()
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let tasks = try queryTasks(
            "\(taskSelectSQL) WHERE t.id IN (\(placeholders))",
            values: ids.map(SQLValue.text)
        )
        return try tasks.map { task in
            let match = fused[task.id]!
            return ContextSearchResult(
                task: task,
                score: match.score,
                highlights: match.highlights,
                matchReasons: match.reasons.sorted(),
                evidencePreviews: try evidence(for: task.id, limit: 3)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.task.isPinned != rhs.task.isPinned { return lhs.task.isPinned }
            return lhs.task.endedAt > rhs.task.endedAt
        }
        .prefix(min(max(query.limit, 1), 50))
        .map { $0 }
    }

    func recall(_ query: MemoryQuery) async throws -> ContextPack {
        ContextPack(query: query.text, results: try await search(query), generatedAt: .now)
    }

    func renameTask(id: String, title: String) throws {
        try prepareIfNeeded()
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160 else { throw ContextStoreError.invalid("Enter a title up to 160 characters.") }
        try withStatement(
            "UPDATE task_episodes_v2 SET user_title = ?, is_user_locked = 1 WHERE id = ?",
            values: [.text(value), .text(id)]
        ) { try stepDone($0) }
        try recordCorrection(.rename, taskIDs: [id], payload: value)
        try reindexTask(id)
    }

    func setPinned(_ pinned: Bool, taskID: String) throws {
        try prepareIfNeeded()
        try withStatement(
            "UPDATE task_episodes_v2 SET pinned = ?, is_user_locked = 1 WHERE id = ?",
            values: [.int(pinned ? 1 : 0), .text(taskID)]
        ) { try stepDone($0) }
        try recordCorrection(.pin, taskIDs: [taskID], payload: pinned ? "true" : "false")
    }

    func assignTask(_ taskID: String, toWorkstream workstreamID: String?) throws {
        try prepareIfNeeded()
        var values: [SQLValue] = []
        let assignment: String
        if let workstreamID {
            assignment = "?"
            values.append(.text(workstreamID))
        } else {
            assignment = "NULL"
        }
        values.append(.text(taskID))
        try withStatement(
            "UPDATE task_episodes_v2 SET workstream_id = \(assignment), is_user_locked = 1 WHERE id = ?",
            values: values
        ) { try stepDone($0) }
        try recordCorrection(.assignWorkstream, taskIDs: [taskID], payload: workstreamID ?? "none")
        try rebuildTask(taskID)
        enqueueDerivation(taskID)
    }

    func mergeTasks(_ taskIDs: [String]) throws {
        try prepareIfNeeded()
        let unique = Array(Set(taskIDs))
        guard unique.count >= 2 else { throw ContextStoreError.invalid("Select at least two tasks to merge.") }
        let tasks = try unique.compactMap { try task(id: $0) }
        guard tasks.count == unique.count, Set(tasks.map(\.sessionID)).count == 1 else {
            throw ContextStoreError.invalid("Only tasks from the same session can be merged.")
        }
        let target = tasks.min(by: { $0.startedAt < $1.startedAt })!.id
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for source in unique where source != target { try mergeTask(source, into: target, userInitiated: true) }
            try recordCorrection(.merge, taskIDs: unique, payload: target)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        enqueueDerivation(target)
    }

    @discardableResult
    func moveSpans(_ spanIDs: [String], to taskID: String?) throws -> String {
        try prepareIfNeeded()
        guard !spanIDs.isEmpty else { throw ContextStoreError.invalid("Select at least one span.") }
        let placeholders = spanIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try stringRows(
            "SELECT DISTINCT task_id, session_id FROM activity_spans WHERE id IN (\(placeholders))",
            values: spanIDs.map(SQLValue.text), columns: 2
        )
        guard rows.count == 1, let sourceID = rows.first?[0], let sessionID = rows.first?[1] else {
            throw ContextStoreError.invalid("Selected spans must belong to one task and session.")
        }
        let destinationID: String
        if let taskID {
            guard let destination = try task(id: taskID), destination.sessionID == sessionID else {
                throw ContextStoreError.invalid("Spans can move only within their session.")
            }
            destinationID = taskID
        } else {
            destinationID = try createTaskForSplit(sourceID: sourceID, sessionID: sessionID)
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            var values: [SQLValue] = [.text(destinationID)]
            values.append(contentsOf: spanIDs.map(SQLValue.text))
            try withStatement(
                "UPDATE activity_spans SET task_id = ? WHERE id IN (\(placeholders))",
                values: values
            ) { try stepDone($0) }
            var evidenceValues: [SQLValue] = [.text(destinationID)]
            evidenceValues.append(contentsOf: spanIDs.map(SQLValue.text))
            try withStatement(
                """
                UPDATE evidence_items SET task_id = ? WHERE observation_id IN (
                    SELECT observation_id FROM span_observations WHERE span_id IN (\(placeholders))
                )
                """,
                values: evidenceValues
            ) { try stepDone($0) }
            try rebuildTask(sourceID)
            try rebuildTask(destinationID)
            try recordCorrection(taskID == nil ? .split : .moveSpan, taskIDs: [sourceID, destinationID], payload: spanIDs.joined(separator: ","))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        enqueueDerivation(sourceID)
        enqueueDerivation(destinationID)
        return destinationID
    }

    func deleteTask(id: String) throws {
        try prepareIfNeeded()
        let observationIDs = try stringColumn(
            """
            SELECT so.observation_id FROM span_observations so
            JOIN activity_spans sp ON sp.id = so.span_id WHERE sp.task_id = ?
            """,
            values: [.text(id)]
        )
        let legacyIDs = observationIDs.isEmpty ? [] : try stringColumn(
            "SELECT DISTINCT episode_id FROM observations WHERE id IN (\(observationIDs.map { _ in "?" }.joined(separator: ",")))",
            values: observationIDs.map(SQLValue.text)
        )
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try recordCorrection(.delete, taskIDs: [id], payload: "deleted")
            try withStatement("DELETE FROM task_v2_fts WHERE task_id = ?", values: [.text(id)]) { try stepDone($0) }
            try withStatement("DELETE FROM task_episodes_v2 WHERE id = ?", values: [.text(id)]) { try stepDone($0) }
            if !observationIDs.isEmpty {
                try withStatement(
                    "DELETE FROM observations WHERE id IN (\(observationIDs.map { _ in "?" }.joined(separator: ",")))",
                    values: observationIDs.map(SQLValue.text)
                ) { try stepDone($0) }
            }
            for legacyID in legacyIDs { try rebuildLegacyEpisode(legacyID) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Preparation and migration

    private func prepareIfNeeded() throws {
        if database != nil { return }
        do {
            let directory = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var handle: OpaquePointer?
            guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let handle else {
                throw ContextStoreError.sqlite("Unable to open the Mnemos database.")
            }
            database = handle
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try migrateV2()
            try backfillIfNeeded()
            try closeStaleState(now: .now)
            try pruneExpiredObservations(now: .now)
            applyPrivateFilePermissions()
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }

    private func migrateV2() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statements = [
                """
                CREATE TABLE IF NOT EXISTS workstreams (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, canonical_key TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL, user_confirmed INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS workstream_anchors (
                    id TEXT PRIMARY KEY, workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, canonical_value TEXT NOT NULL, strength REAL NOT NULL,
                    user_confirmed INTEGER NOT NULL DEFAULT 0, UNIQUE(kind, canonical_value)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS work_sessions (
                    id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL NOT NULL,
                    last_observation_at REAL NOT NULL, is_open INTEGER NOT NULL DEFAULT 1
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS task_episodes_v2 (
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                    workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
                    started_at REAL NOT NULL, ended_at REAL NOT NULL, last_observation_at REAL NOT NULL,
                    title TEXT NOT NULL, user_title TEXT, digest TEXT NOT NULL,
                    actions_json TEXT NOT NULL DEFAULT '[]', applications_json TEXT NOT NULL DEFAULT '[]',
                    artifacts_json TEXT NOT NULL DEFAULT '[]', last_state TEXT, event_count INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0, grouping_confidence REAL NOT NULL DEFAULT 0.5,
                    grouping_reasons_json TEXT NOT NULL DEFAULT '[]', is_open INTEGER NOT NULL DEFAULT 1,
                    is_user_locked INTEGER NOT NULL DEFAULT 0
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS activity_spans (
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                    task_id TEXT NOT NULL REFERENCES task_episodes_v2(id) ON DELETE CASCADE,
                    started_at REAL NOT NULL, ended_at REAL NOT NULL, last_observation_at REAL NOT NULL,
                    application_name TEXT NOT NULL, bundle_id TEXT NOT NULL, window_title TEXT,
                    document_path TEXT, url TEXT, anchor_key TEXT, event_count INTEGER NOT NULL DEFAULT 0,
                    is_open INTEGER NOT NULL DEFAULT 1
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS span_observations (
                    span_id TEXT NOT NULL REFERENCES activity_spans(id) ON DELETE CASCADE,
                    observation_id TEXT NOT NULL REFERENCES observations(id) ON DELETE CASCADE UNIQUE,
                    PRIMARY KEY(span_id, observation_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS evidence_items (
                    id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES task_episodes_v2(id) ON DELETE CASCADE,
                    observation_id TEXT REFERENCES observations(id) ON DELETE SET NULL,
                    timestamp REAL NOT NULL, kind TEXT NOT NULL, application_name TEXT NOT NULL,
                    excerpt TEXT, url TEXT, document_path TEXT, target TEXT, source TEXT NOT NULL,
                    priority INTEGER NOT NULL, redaction_policy_version INTEGER NOT NULL,
                    user_selected INTEGER NOT NULL DEFAULT 0, UNIQUE(task_id, observation_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS episode_embeddings (
                    task_id TEXT NOT NULL REFERENCES task_episodes_v2(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL, language TEXT NOT NULL, revision INTEGER NOT NULL,
                    dimension INTEGER NOT NULL, content_hash TEXT NOT NULL, vector BLOB NOT NULL,
                    updated_at REAL NOT NULL, PRIMARY KEY(task_id, provider, language, revision)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS memory_corrections (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, task_ids_json TEXT NOT NULL,
                    payload TEXT, created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS derivation_state (
                    id INTEGER PRIMARY KEY CHECK(id = 1), status TEXT NOT NULL,
                    last_observation_at REAL, algorithm_version INTEGER NOT NULL, updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS redaction_metrics (
                    category TEXT NOT NULL, policy_version INTEGER NOT NULL,
                    count INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL,
                    PRIMARY KEY(category, policy_version)
                )
                """,
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS task_v2_fts USING fts5(
                    task_id UNINDEXED, title, digest, workstream, applications, artifacts, evidence,
                    tokenize='unicode61 remove_diacritics 2'
                )
                """,
                "CREATE INDEX IF NOT EXISTS workstream_anchors_lookup_idx ON workstream_anchors(kind, canonical_value)",
                "CREATE INDEX IF NOT EXISTS work_sessions_ended_idx ON work_sessions(ended_at DESC)",
                "CREATE INDEX IF NOT EXISTS task_v2_session_idx ON task_episodes_v2(session_id, ended_at DESC)",
                "CREATE INDEX IF NOT EXISTS task_v2_workstream_idx ON task_episodes_v2(workstream_id, ended_at DESC)",
                "CREATE INDEX IF NOT EXISTS spans_task_idx ON activity_spans(task_id, started_at)",
                "CREATE INDEX IF NOT EXISTS evidence_task_idx ON evidence_items(task_id, timestamp)",
                "INSERT OR IGNORE INTO derivation_state(id, status, algorithm_version, updated_at) VALUES(1, 'pending', 5, strftime('%s','now'))",
                "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, strftime('%s','now'))",
            ]
            for statement in statements { try execute(statement) }
            if try !columnExists(table: "observations", column: "redaction_policy_version") {
                try execute("ALTER TABLE observations ADD COLUMN redaction_policy_version INTEGER NOT NULL DEFAULT 1")
            }
            let algorithm = try scalarInt("SELECT algorithm_version FROM derivation_state WHERE id = 1")
            if algorithm < Self.algorithmVersion {
                try execute("DELETE FROM task_v2_fts")
                try execute("DELETE FROM episode_embeddings")
                try execute("DELETE FROM evidence_items")
                try execute("DELETE FROM span_observations")
                try execute("DELETE FROM activity_spans")
                try execute("DELETE FROM task_episodes_v2")
                try execute("DELETE FROM work_sessions")
                try execute("UPDATE derivation_state SET status = 'pending', last_observation_at = NULL, algorithm_version = 5")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func backfillIfNeeded() throws {
        let unassigned = try scalarInt(
            """
            SELECT COUNT(*) FROM observations o
            LEFT JOIN span_observations so ON so.observation_id = o.id
            WHERE so.observation_id IS NULL
            """
        )
        guard unassigned > 0 else {
            try execute("UPDATE derivation_state SET status = 'complete', updated_at = strftime('%s','now') WHERE id = 1")
            if semanticSearchEnabled {
                for id in try stringColumn(
                    """
                    SELECT t.id FROM task_episodes_v2 t
                    LEFT JOIN episode_embeddings e ON e.task_id = t.id
                    WHERE e.task_id IS NULL
                    """
                ) { enqueueDerivation(id) }
            }
            return
        }
        try execute("UPDATE derivation_state SET status = 'indexing', updated_at = strftime('%s','now') WHERE id = 1")
        var observations: [Observation] = []
        try withStatement(
            """
            SELECT o.id, o.timestamp, o.kind, o.application_name, o.bundle_id, o.window_title,
                   o.document_path, o.url, o.target_role, o.target_title, o.target_identifier,
                   o.detail, o.ax_text
            FROM observations o
            LEFT JOIN span_observations so ON so.observation_id = o.id
            WHERE so.observation_id IS NULL
            ORDER BY o.timestamp
            """
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let target = [columnText(statement, 8), columnText(statement, 9), columnText(statement, 10)]
                    .compactMap { $0 }.joined(separator: " · ")
                observations.append(Observation(
                    id: columnText(statement, 0) ?? UUID().uuidString,
                    timestamp: dateColumn(statement, 1),
                    kind: columnText(statement, 2) ?? "Unknown",
                    applicationName: columnText(statement, 3) ?? "Unknown",
                    bundleID: columnText(statement, 4) ?? "unknown",
                    windowTitle: columnText(statement, 5), documentPath: columnText(statement, 6),
                    url: columnText(statement, 7), target: target.isEmpty ? nil : target,
                    detail: columnText(statement, 11), axText: columnText(statement, 12)
                ))
            }
        }
        for chunk in observations.chunked(into: 500) {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                for observation in chunk { _ = try derive(observation) }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        try execute("UPDATE derivation_state SET status = 'complete', updated_at = strftime('%s','now') WHERE id = 1")
        for id in try stringColumn("SELECT id FROM task_episodes_v2") { enqueueDerivation(id) }
    }

    // MARK: - Online derivation

    private func derive(_ observation: Observation) throws -> String {
        try recordRedactionMetrics(observation)
        let session = try session(for: observation.timestamp)
        let anchor = resolveAnchor(for: observation)
        let workstreamID = try anchor.map(resolveWorkstream)
        let span = try reusableSpan(sessionID: session.id, observation: observation, anchor: anchor)
        let taskID: String
        let spanID: String

        if let span {
            taskID = span.taskID
            spanID = span.id
        } else {
            try closeOpenSpans(sessionID: session.id, at: observation.timestamp)
            let selected = try selectTaskCandidate(
                sessionID: session.id,
                observation: observation,
                workstreamID: workstreamID
            )
            taskID = try selected?.id ?? createTask(
                sessionID: session.id,
                workstreamID: workstreamID,
                observation: observation,
                confidence: selected == nil ? 0.45 : 0.75,
                reasons: selected == nil ? ["new_context"] : ["same_context"]
            )
            spanID = try createSpan(
                sessionID: session.id,
                taskID: taskID,
                observation: observation,
                anchorKey: anchor?.canonicalKey
            )
        }

        try withStatement(
            "INSERT OR IGNORE INTO span_observations(span_id, observation_id) VALUES(?, ?)",
            values: [.text(spanID), .text(observation.id)]
        ) { try stepDone($0) }
        try updateSpan(spanID, with: observation)
        try updateSession(session.id, with: observation)
        try updateTask(taskID, workstreamID: workstreamID, with: observation)
        try withStatement(
            "UPDATE observations SET redaction_policy_version = ? WHERE id = ?",
            values: [.int(CapturePrivacy.redactionPolicyVersion), .text(observation.id)]
        ) { try stepDone($0) }
        try withStatement(
            "UPDATE derivation_state SET last_observation_at = ?, updated_at = ? WHERE id = 1",
            values: [.double(observation.timestamp.timeIntervalSince1970), .double(Date.now.timeIntervalSince1970)]
        ) { try stepDone($0) }

        if observation.kind == CapturedEvent.Kind.session.rawValue {
            let detail = observation.detail ?? ""
            if detail.localizedCaseInsensitiveContains("paused")
                || detail.localizedCaseInsensitiveContains("sleep")
                || detail.localizedCaseInsensitiveContains("lock") {
                try closeSession(session.id, at: observation.timestamp)
            }
        }
        return taskID
    }

    private func recordRedactionMetrics(_ observation: Observation) throws {
        let counts = CapturePrivacy.redactionCategoryCounts(in: [
            observation.windowTitle, observation.documentPath, observation.url,
            observation.target, observation.detail, observation.axText,
        ])
        for (category, count) in counts {
            try withStatement(
                """
                INSERT INTO redaction_metrics(category, policy_version, count, updated_at)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(category, policy_version) DO UPDATE SET
                    count = count + excluded.count, updated_at = excluded.updated_at
                """,
                values: [
                    .text(category), .int(CapturePrivacy.redactionPolicyVersion), .int(count),
                    .double(Date.now.timeIntervalSince1970),
                ]
            ) { try stepDone($0) }
        }
    }

    private func session(for date: Date) throws -> OpenSession {
        var current: OpenSession?
        try withStatement(
            "SELECT id, last_observation_at FROM work_sessions WHERE is_open = 1 ORDER BY last_observation_at DESC LIMIT 1"
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                current = OpenSession(id: columnText(statement, 0) ?? "unknown", lastObservationAt: dateColumn(statement, 1))
            }
        }
        if let current, date.timeIntervalSince(current.lastObservationAt) <= Self.sessionIdleSeconds {
            return current
        }
        if let current { try closeSession(current.id, at: current.lastObservationAt) }
        let id = UUID().uuidString.lowercased()
        try withStatement(
            "INSERT INTO work_sessions(id, started_at, ended_at, last_observation_at, is_open) VALUES(?, ?, ?, ?, 1)",
            values: [.text(id), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)]
        ) { try stepDone($0) }
        return OpenSession(id: id, lastObservationAt: date)
    }

    private func reusableSpan(sessionID: String, observation: Observation, anchor: Anchor?) throws -> OpenSpan? {
        var span: OpenSpan?
        try withStatement(
            """
            SELECT id, task_id, bundle_id, window_title, anchor_key, last_observation_at
            FROM activity_spans WHERE session_id = ? AND is_open = 1
            ORDER BY last_observation_at DESC LIMIT 1
            """,
            values: [.text(sessionID)]
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                span = OpenSpan(
                    id: columnText(statement, 0) ?? "unknown", taskID: columnText(statement, 1) ?? "unknown",
                    bundleID: columnText(statement, 2) ?? "unknown", windowTitle: columnText(statement, 3),
                    anchorKey: columnText(statement, 4), lastObservationAt: dateColumn(statement, 5)
                )
            }
        }
        guard let span,
              observation.timestamp.timeIntervalSince(span.lastObservationAt) <= Self.spanIdleSeconds,
              span.bundleID == observation.bundleID,
              Self.normalized(span.windowTitle) == Self.normalized(observation.windowTitle),
              span.anchorKey == anchor?.canonicalKey else { return nil }
        return span
    }

    private func selectTaskCandidate(
        sessionID: String,
        observation: Observation,
        workstreamID: String?
    ) throws -> TaskMemory? {
        let cutoff = observation.timestamp.addingTimeInterval(-Self.taskCandidateSeconds).timeIntervalSince1970
        if let workstreamID {
            if let matchingID = try scalarText(
                """
                SELECT candidate.id FROM (
                    SELECT id, workstream_id FROM task_episodes_v2
                    WHERE session_id = ? AND last_observation_at >= ?
                    ORDER BY last_observation_at DESC LIMIT \(Self.maximumTaskCandidates)
                ) candidate
                WHERE candidate.workstream_id = ? LIMIT 1
                """,
                values: [.text(sessionID), .double(cutoff), .text(workstreamID)]
            ), let matching = try task(id: matchingID) { return matching }
            if !Self.isCommunicationApp(observation.bundleID, name: observation.applicationName) {
                return try sameContextTask(sessionID: sessionID, observation: observation, cutoff: observation.timestamp.addingTimeInterval(-Self.semanticContinuitySeconds))
            }
            return nil
        }
        return try sameContextTask(sessionID: sessionID, observation: observation, cutoff: Date(timeIntervalSince1970: cutoff))
    }

    private func sameContextTask(sessionID: String, observation: Observation, cutoff: Date) throws -> TaskMemory? {
        let id = try scalarText(
            """
            SELECT candidate.id FROM (
                SELECT id FROM task_episodes_v2
                WHERE session_id = ? AND last_observation_at >= ?
                ORDER BY last_observation_at DESC LIMIT \(Self.maximumTaskCandidates)
            ) candidate
            JOIN activity_spans sp ON sp.task_id = candidate.id
            WHERE 1 = 1
              AND sp.bundle_id = ? AND COALESCE(sp.window_title, '') = ?
            LIMIT 1
            """,
            values: [
                .text(sessionID), .double(cutoff.timeIntervalSince1970), .text(observation.bundleID),
                .text(observation.windowTitle ?? ""),
            ]
        )
        guard let id else { return nil }
        return try task(id: id)
    }

    private func createTask(
        sessionID: String,
        workstreamID: String?,
        observation: Observation,
        confidence: Double,
        reasons: [String]
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let title = observation.windowTitle.map { String($0.prefix(120)) } ?? "Activity in \(observation.applicationName)"
        try withStatement(
            """
            INSERT INTO task_episodes_v2(
                id, session_id, workstream_id, started_at, ended_at, last_observation_at,
                title, digest, grouping_confidence, grouping_reasons_json, is_open
            ) VALUES(?, ?, ?, ?, ?, ?, ?, 'New task activity.', ?, ?, 1)
            """,
            values: [
                .text(id), .text(sessionID), workstreamID.map(SQLValue.text) ?? .text(""),
                .double(observation.timestamp.timeIntervalSince1970), .double(observation.timestamp.timeIntervalSince1970),
                .double(observation.timestamp.timeIntervalSince1970), .text(title), .double(confidence), .text(encodeJSON(reasons)),
            ]
        ) { statement in
            if workstreamID == nil { sqlite3_bind_null(statement, 3) }
            try stepDone(statement)
        }
        return id
    }

    private func createSpan(sessionID: String, taskID: String, observation: Observation, anchorKey: String?) throws -> String {
        let id = UUID().uuidString.lowercased()
        try withStatement(
            """
            INSERT INTO activity_spans(
                id, session_id, task_id, started_at, ended_at, last_observation_at,
                application_name, bundle_id, window_title, document_path, url, anchor_key, event_count, is_open
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1)
            """,
            values: [
                .text(id), .text(sessionID), .text(taskID),
                .double(observation.timestamp.timeIntervalSince1970), .double(observation.timestamp.timeIntervalSince1970),
                .double(observation.timestamp.timeIntervalSince1970), .text(observation.applicationName), .text(observation.bundleID),
                .text(observation.windowTitle ?? ""), .text(observation.documentPath ?? ""),
                .text(observation.url ?? ""), .text(anchorKey ?? ""),
            ]
        ) { statement in
            for (index, value) in [(9, observation.windowTitle), (10, observation.documentPath), (11, observation.url), (12, anchorKey)] where value == nil {
                sqlite3_bind_null(statement, Int32(index))
            }
            try stepDone(statement)
        }
        return id
    }

    private func updateSpan(_ id: String, with observation: Observation) throws {
        try withStatement(
            "UPDATE activity_spans SET ended_at = ?, last_observation_at = ?, event_count = event_count + 1 WHERE id = ?",
            values: [.double(observation.timestamp.timeIntervalSince1970), .double(observation.timestamp.timeIntervalSince1970), .text(id)]
        ) { try stepDone($0) }
    }

    private func updateSession(_ id: String, with observation: Observation) throws {
        try withStatement(
            "UPDATE work_sessions SET ended_at = ?, last_observation_at = ? WHERE id = ?",
            values: [.double(observation.timestamp.timeIntervalSince1970), .double(observation.timestamp.timeIntervalSince1970), .text(id)]
        ) { try stepDone($0) }
    }

    private func updateTask(_ id: String, workstreamID: String?, with observation: Observation) throws {
        guard let existing = try task(id: id) else { return }
        var sql = "UPDATE task_episodes_v2 SET ended_at = ?, last_observation_at = ?, event_count = event_count + 1"
        var values: [SQLValue] = [
            .double(observation.timestamp.timeIntervalSince1970), .double(observation.timestamp.timeIntervalSince1970),
        ]
        if existing.workstream == nil, let workstreamID, !existing.isUserLocked {
            sql += ", workstream_id = ?, grouping_confidence = 1.0, grouping_reasons_json = ?"
            values.append(.text(workstreamID))
            values.append(.text(encodeJSON(["strong_anchor"])))
        }
        sql += " WHERE id = ?"
        values.append(.text(id))
        try withStatement(sql, values: values) { try stepDone($0) }
    }

    private func retainEvidence(_ observation: Observation, taskID: String) throws {
        let selection = Self.evidenceSelection(for: observation)
        guard selection.priority > 0, let excerpt = selection.excerpt else { return }
        let sanitized = CapturePrivacy.sanitize(excerpt, maximumLength: 2_000, preserveLines: true)
        guard let sanitized else { return }
        try withStatement(
            """
            INSERT OR REPLACE INTO evidence_items(
                id, task_id, observation_id, timestamp, kind, application_name, excerpt,
                url, document_path, target, source, priority, redaction_policy_version, user_selected
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'raw', ?, ?, 0)
            """,
            values: [
                .text(observation.id), .text(taskID), .text(observation.id), .double(observation.timestamp.timeIntervalSince1970),
                .text(observation.kind), .text(observation.applicationName), .text(sanitized), .text(observation.url ?? ""),
                .text(observation.documentPath ?? ""), .text(observation.target ?? ""), .int(selection.priority),
                .int(CapturePrivacy.redactionPolicyVersion),
            ]
        ) { statement in
            for (index, value) in [(8, observation.url), (9, observation.documentPath), (10, observation.target)] where value == nil {
                sqlite3_bind_null(statement, Int32(index))
            }
            try stepDone(statement)
        }
    }

    private func selectDiverseEvidence(for taskID: String) throws {
        var candidates: [EvidenceCandidate] = []
        try withStatement(
            """
            SELECT id, COALESCE(excerpt, ''), application_name, kind, priority, user_selected, timestamp
            FROM evidence_items WHERE task_id = ?
            """,
            values: [.text(taskID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                candidates.append(EvidenceCandidate(
                    id: columnText(statement, 0) ?? "",
                    excerpt: columnText(statement, 1) ?? "",
                    application: columnText(statement, 2) ?? "Unknown",
                    kind: columnText(statement, 3) ?? "Unknown",
                    priority: Int(sqlite3_column_int64(statement, 4)),
                    userSelected: sqlite3_column_int64(statement, 5) == 1,
                    timestamp: dateColumn(statement, 6)
                ))
            }
        }
        var selected: [EvidenceCandidate] = []
        var remaining = candidates
        var fingerprints = Set<String>()
        var applicationCounts: [String: Int] = [:]
        var kindCounts: [String: Int] = [:]
        while selected.count < Self.maximumEvidenceItems, !remaining.isEmpty {
            remaining.sort { lhs, rhs in
                let left = (lhs.userSelected ? 10_000 : 0) + lhs.priority
                    - applicationCounts[lhs.application, default: 0] * 12
                    - kindCounts[lhs.kind, default: 0] * 8
                let right = (rhs.userSelected ? 10_000 : 0) + rhs.priority
                    - applicationCounts[rhs.application, default: 0] * 12
                    - kindCounts[rhs.kind, default: 0] * 8
                return left == right ? lhs.timestamp > rhs.timestamp : left > right
            }
            let candidate = remaining.removeFirst()
            let fingerprint = candidate.excerpt.lowercased()
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard candidate.userSelected || !fingerprints.contains(fingerprint) else { continue }
            selected.append(candidate)
            fingerprints.insert(fingerprint)
            applicationCounts[candidate.application, default: 0] += 1
            kindCounts[candidate.kind, default: 0] += 1
        }
        let kept = Set(selected.map(\.id))
        let removed = candidates.map(\.id).filter { !kept.contains($0) }
        guard !removed.isEmpty else { return }
        try withStatement(
            "DELETE FROM evidence_items WHERE id IN (\(removed.map { _ in "?" }.joined(separator: ",")))",
            values: removed.map(SQLValue.text)
        ) { try stepDone($0) }
    }

    // MARK: - Workstreams

    private func resolveWorkstream(_ anchor: Anchor) throws -> String {
        for value in anchor.values {
            if let id = try scalarText(
                "SELECT workstream_id FROM workstream_anchors WHERE kind = ? AND canonical_value = ? LIMIT 1",
                values: [.text(value.kind), .text(value.value)]
            ) { return id }
        }
        if let id = try scalarText("SELECT id FROM workstreams WHERE canonical_key = ?", values: [.text(anchor.canonicalKey)]) {
            try insertAnchors(anchor.values, workstreamID: id)
            return id
        }
        let id = UUID().uuidString.lowercased()
        let now = Date.now.timeIntervalSince1970
        try withStatement(
            "INSERT INTO workstreams(id, kind, canonical_key, display_name, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)",
            values: [.text(id), .text(anchor.kind.rawValue), .text(anchor.canonicalKey), .text(anchor.displayName), .double(now), .double(now)]
        ) { try stepDone($0) }
        try insertAnchors(anchor.values, workstreamID: id)
        return id
    }

    private func insertAnchors(_ anchors: [(kind: String, value: String, strength: Double)], workstreamID: String) throws {
        for anchor in anchors {
            try withStatement(
                "INSERT OR IGNORE INTO workstream_anchors(id, workstream_id, kind, canonical_value, strength) VALUES(?, ?, ?, ?, ?)",
                values: [.text(UUID().uuidString.lowercased()), .text(workstreamID), .text(anchor.kind), .text(anchor.value), .double(anchor.strength)]
            ) { try stepDone($0) }
        }
    }

    private func workstream(id: String) throws -> Workstream? {
        var result: Workstream?
        try withStatement(
            "SELECT id, kind, canonical_key, display_name, user_confirmed FROM workstreams WHERE id = ? LIMIT 1",
            values: [.text(id)]
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { result = decodeWorkstream(statement, offset: 0) }
        }
        return result
    }

    private func resolveAnchor(for observation: Observation) -> Anchor? {
        let cacheKey = observation.documentPath ?? observation.url ?? ""
        if let cached = anchorCache[cacheKey] { return cached }
        let anchor: Anchor?
        if let path = observation.documentPath {
            anchor = Self.fileAnchor(path)
        } else if let value = observation.url, let url = URL(string: value), let host = url.host?.lowercased() {
            let parts = url.pathComponents.filter { $0 != "/" }
            if host == "github.com", parts.count >= 2 {
                let key = "github.com/\(parts[0].lowercased())/\(parts[1].lowercased().replacingOccurrences(of: ".git", with: ""))"
                anchor = Anchor(
                    kind: .gitRepository, canonicalKey: key, displayName: parts[1].replacingOccurrences(of: ".git", with: ""),
                    values: [("repository", key, 1.0), ("url", "https://\(key)", 0.95)]
                )
            } else {
                let key = "website:\(host)"
                anchor = Anchor(kind: .website, canonicalKey: key, displayName: host, values: [("domain", host, 0.65)])
            }
        } else {
            anchor = nil
        }
        if !cacheKey.isEmpty, let anchor { anchorCache[cacheKey] = anchor }
        return anchor
    }

    private static func fileAnchor(_ path: String) -> Anchor {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var directory = url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var repositoryRoot: URL?
        while directory.path.count >= home.count, directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                repositoryRoot = directory
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        let root = repositoryRoot ?? (url.pathExtension.isEmpty ? url : url.deletingLastPathComponent())
        var canonical = "local:\(root.path)"
        var values: [(String, String, Double)] = [("path", root.path, repositoryRoot == nil ? 0.8 : 1.0)]
        if let repositoryRoot,
           let config = try? String(contentsOf: repositoryRoot.appendingPathComponent(".git/config"), encoding: .utf8),
           let github = githubRepositoryKey(in: config) {
            canonical = github
            values.append(("repository", github, 1.0))
        }
        return Anchor(
            kind: repositoryRoot == nil ? .localProject : .gitRepository,
            canonicalKey: canonical,
            displayName: root.lastPathComponent,
            values: values
        )
    }

    private static func githubRepositoryKey(in config: String) -> String? {
        let patterns = [
            #"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?(?:\s|$)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: config, range: NSRange(config.startIndex..., in: config)),
                  match.numberOfRanges >= 3,
                  let ownerRange = Range(match.range(at: 1), in: config),
                  let repoRange = Range(match.range(at: 2), in: config) else { continue }
            return "github.com/\(config[ownerRange].lowercased())/\(config[repoRange].lowercased().replacingOccurrences(of: ".git", with: ""))"
        }
        return nil
    }

    // MARK: - Background derivation and indexing

    private func enqueueDerivation(_ taskID: String, delayMilliseconds: Int = 150) {
        derivationTasks[taskID]?.cancel()
        let token = UUID()
        derivationTokens[taskID] = token
        derivationTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            await self.refreshDerivedTask(taskID, token: token)
        }
    }

    private func refreshDerivedTask(_ taskID: String, token: UUID) async {
        defer {
            if derivationTokens[taskID] == token {
                derivationTokens.removeValue(forKey: taskID)
                derivationTasks.removeValue(forKey: taskID)
            }
        }
        do {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            try rebuildTask(taskID, lockGrouping: false, regenerateEvidence: true)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            semanticIndexIssue = "Task derivation failed: \(error.localizedDescription)"
            return
        }
        guard semanticSearchEnabled, let task = try? task(id: taskID) else { return }
        let text = Self.embeddingText(for: task, evidence: (try? evidence(for: taskID, limit: Self.maximumEvidenceItems)) ?? [])
        guard let vector = await embeddingProvider.embed(text) else {
            semanticIndexIssue = "Apple sentence embedding is unavailable for one or more task languages; FTS remains active."
            return
        }
        do {
            try withStatement(
                """
                INSERT OR REPLACE INTO episode_embeddings(
                    task_id, provider, language, revision, dimension, content_hash, vector, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values: [
                    .text(taskID), .text(vector.provider), .text(vector.language), .int(vector.revision),
                    .int(vector.dimension), .text(vector.contentHash), .blob(vector.data),
                    .double(Date.now.timeIntervalSince1970),
                ]
            ) { try stepDone($0) }
            semanticIndexIssue = nil
            try semanticReconcile(taskID: taskID, vector: vector)
        } catch {
            semanticIndexIssue = "Semantic index update failed: \(error.localizedDescription)"
            return
        }
    }

    private func semanticReconcile(taskID: String, vector: SemanticVector) throws {
        guard let source = try task(id: taskID), !source.isUserLocked, source.workstream == nil,
              !source.applications.contains(where: { Self.isCommunicationApp("", name: $0) }) else { return }
        let candidates = try queryTasks(
            """
            \(taskSelectSQL)
            WHERE t.session_id = ? AND t.id <> ? AND t.is_user_locked = 0
              AND ABS(t.last_observation_at - ?) <= ?
            ORDER BY t.last_observation_at DESC LIMIT \(Self.maximumTaskCandidates)
            """,
            values: [
                .text(source.sessionID), .text(source.id), .double(source.startedAt.timeIntervalSince1970),
                .double(Self.semanticContinuitySeconds),
            ]
        )
        for candidate in candidates where !candidate.applications.contains(where: { Self.isCommunicationApp("", name: $0) }) {
            var stored: [Float]?
            try withStatement(
                """
                SELECT vector FROM episode_embeddings
                WHERE task_id = ? AND provider = ? AND language = ? AND revision = ? AND dimension = ? LIMIT 1
                """,
                values: [
                    .text(candidate.id), .text(vector.provider), .text(vector.language),
                    .int(vector.revision), .int(vector.dimension),
                ]
            ) { statement in
                if sqlite3_step(statement) == SQLITE_ROW, let data = columnData(statement, 0) {
                    stored = AppleSentenceEmbeddingProvider.decode(data, dimension: vector.dimension)
                }
            }
            guard let stored,
                  let similarity = AppleSentenceEmbeddingProvider.cosine(vector.values, stored),
                  similarity >= 0.78 else { continue }
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try mergeTask(source.id, into: candidate.id, userInitiated: false)
                try execute("COMMIT")
                enqueueDerivation(candidate.id)
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            break
        }
    }

    private func reindexTask(_ taskID: String) throws {
        guard let task = try task(id: taskID) else { return }
        let evidenceText = try evidence(for: taskID, limit: Self.maximumEvidenceItems)
            .compactMap(\.excerpt).joined(separator: "\n")
        try withStatement("DELETE FROM task_v2_fts WHERE task_id = ?", values: [.text(taskID)]) { try stepDone($0) }
        try withStatement(
            "INSERT INTO task_v2_fts(task_id, title, digest, workstream, applications, artifacts, evidence) VALUES(?, ?, ?, ?, ?, ?, ?)",
            values: [
                .text(taskID), .text(task.title), .text(task.digest), .text(task.workstream?.displayName ?? ""),
                .text(task.applications.joined(separator: " ")), .text(task.artifacts.joined(separator: " ")), .text(evidenceText),
            ]
        ) { try stepDone($0) }
    }

    // MARK: - Corrections and rebuilding

    private func mergeTask(_ sourceID: String, into targetID: String, userInitiated: Bool) throws {
        guard sourceID != targetID else { return }
        try withStatement("UPDATE activity_spans SET task_id = ? WHERE task_id = ?", values: [.text(targetID), .text(sourceID)]) { try stepDone($0) }
        try withStatement("UPDATE evidence_items SET task_id = ? WHERE task_id = ?", values: [.text(targetID), .text(sourceID)]) { try stepDone($0) }
        try withStatement("DELETE FROM task_v2_fts WHERE task_id = ?", values: [.text(sourceID)]) { try stepDone($0) }
        try withStatement("DELETE FROM task_episodes_v2 WHERE id = ?", values: [.text(sourceID)]) { try stepDone($0) }
        try rebuildTask(targetID)
        if userInitiated {
            try withStatement("UPDATE task_episodes_v2 SET is_user_locked = 1 WHERE id = ?", values: [.text(targetID)]) { try stepDone($0) }
        } else {
            try withStatement(
                "UPDATE task_episodes_v2 SET grouping_confidence = 0.78, grouping_reasons_json = ? WHERE id = ?",
                values: [.text(encodeJSON(["semantic_continuity"])), .text(targetID)]
            ) { try stepDone($0) }
        }
    }

    private func createTaskForSplit(sourceID: String, sessionID: String) throws -> String {
        guard let source = try task(id: sourceID) else { throw ContextStoreError.invalid("Source task was not found.") }
        let id = UUID().uuidString.lowercased()
        try withStatement(
            """
            INSERT INTO task_episodes_v2(
                id, session_id, workstream_id, started_at, ended_at, last_observation_at,
                title, digest, grouping_confidence, grouping_reasons_json, is_user_locked, is_open
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1.0, ?, 1, 0)
            """,
            values: [
                .text(id), .text(sessionID), .text(source.workstream?.id ?? ""),
                .double(source.startedAt.timeIntervalSince1970), .double(source.endedAt.timeIntervalSince1970),
                .double(source.endedAt.timeIntervalSince1970), .text(source.title), .text(source.digest),
                .text(encodeJSON(["user_split"])),
            ]
        ) { statement in
            if source.workstream == nil { sqlite3_bind_null(statement, 3) }
            try stepDone(statement)
        }
        return id
    }

    private func rebuildTask(
        _ taskID: String,
        lockGrouping: Bool = true,
        regenerateEvidence: Bool = false
    ) throws {
        guard let original = try task(id: taskID) else { return }
        var observations: [Observation] = []
        try withStatement(
            """
            SELECT o.id, o.timestamp, o.kind, o.application_name, o.bundle_id, o.window_title,
                   o.document_path, o.url, o.target_role, o.target_title, o.target_identifier, o.detail, o.ax_text
            FROM observations o
            JOIN span_observations so ON so.observation_id = o.id
            JOIN activity_spans sp ON sp.id = so.span_id
            WHERE sp.task_id = ? ORDER BY o.timestamp
            """,
            values: [.text(taskID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let target = [columnText(statement, 8), columnText(statement, 9), columnText(statement, 10)].compactMap { $0 }.joined(separator: " · ")
                observations.append(Observation(
                    id: columnText(statement, 0) ?? UUID().uuidString, timestamp: dateColumn(statement, 1),
                    kind: columnText(statement, 2) ?? "Unknown", applicationName: columnText(statement, 3) ?? "Unknown",
                    bundleID: columnText(statement, 4) ?? "unknown", windowTitle: columnText(statement, 5),
                    documentPath: columnText(statement, 6), url: columnText(statement, 7), target: target.isEmpty ? nil : target,
                    detail: columnText(statement, 11), axText: columnText(statement, 12)
                ))
            }
        }
        guard let first = observations.first, let last = observations.last else {
            try withStatement("DELETE FROM task_episodes_v2 WHERE id = ?", values: [.text(taskID)]) { try stepDone($0) }
            return
        }
        let applications = Set(observations.map(\.applicationName)).sorted()
        let artifacts = Set(observations.flatMap { [$0.documentPath, $0.url].compactMap { $0 } }).sorted()
        let actions = Set(observations.map { Self.action(for: $0.kind) }).sorted()
        let lastState = Self.lastState(for: last)
        let digest = Self.digest(workstream: original.workstream, applications: applications, actions: actions, artifacts: artifacts, lastState: lastState)
        let title = original.workstream.map { "Working on \($0.displayName)" }
            ?? last.windowTitle.map { String($0.prefix(120)) }
            ?? original.title
        try withStatement(
            """
            UPDATE task_episodes_v2 SET started_at = ?, ended_at = ?, last_observation_at = ?,
                title = ?, digest = ?, actions_json = ?, applications_json = ?, artifacts_json = ?,
                last_state = ?, event_count = ?, is_user_locked = ? WHERE id = ?
            """,
            values: [
                .double(first.timestamp.timeIntervalSince1970), .double(last.timestamp.timeIntervalSince1970),
                .double(last.timestamp.timeIntervalSince1970), .text(title), .text(digest), .text(encodeJSON(actions)),
                .text(encodeJSON(applications)), .text(encodeJSON(Array(artifacts.prefix(60)))), .text(lastState ?? ""),
                .int(observations.count), .int(lockGrouping || original.isUserLocked ? 1 : 0), .text(taskID),
            ]
        ) { statement in
            if lastState == nil { sqlite3_bind_null(statement, 9) }
            try stepDone(statement)
        }
        if regenerateEvidence {
            try withStatement(
                "DELETE FROM evidence_items WHERE task_id = ? AND user_selected = 0",
                values: [.text(taskID)]
            ) { try stepDone($0) }
            for observation in observations { try retainEvidence(observation, taskID: taskID) }
            try selectDiverseEvidence(for: taskID)
        }
        try reindexTask(taskID)
    }

    private func recordCorrection(_ kind: MemoryCorrectionKind, taskIDs: [String], payload: String?) throws {
        try withStatement(
            "INSERT INTO memory_corrections(id, kind, task_ids_json, payload, created_at) VALUES(?, ?, ?, ?, ?)",
            values: [
                .text(UUID().uuidString.lowercased()), .text(kind.rawValue), .text(encodeJSON(taskIDs)),
                .text(payload ?? ""), .double(Date.now.timeIntervalSince1970),
            ]
        ) { statement in
            if payload == nil { sqlite3_bind_null(statement, 4) }
            try stepDone(statement)
        }
    }

    private func rebuildLegacyEpisode(_ id: String) throws {
        let count = try scalarInt("SELECT COUNT(*) FROM observations WHERE episode_id = ?", values: [.text(id)])
        if count == 0 {
            try withStatement("DELETE FROM episodes WHERE id = ?", values: [.text(id)]) { try stepDone($0) }
            return
        }
        let applications = try stringColumn("SELECT DISTINCT application_name FROM observations WHERE episode_id = ? ORDER BY application_name", values: [.text(id)])
        let artifacts = try stringColumn(
            """
            SELECT value FROM (
                SELECT document_path AS value FROM observations WHERE episode_id = ? AND document_path IS NOT NULL
                UNION SELECT url FROM observations WHERE episode_id = ? AND url IS NOT NULL
            ) LIMIT 40
            """,
            values: [.text(id), .text(id)]
        )
        try withStatement(
            "UPDATE episodes SET applications_json = ?, artifacts_json = ?, event_count = ?, summary = ? WHERE id = ?",
            values: [
                .text(encodeJSON(applications)), .text(encodeJSON(artifacts)), .int(count),
                .text("Legacy activity retained after a privacy deletion. \(count) observations remain."), .text(id),
            ]
        ) { try stepDone($0) }
    }

    // MARK: - Query helpers

    private var taskSelectSQL: String {
        """
        SELECT t.id, t.session_id, t.started_at, t.ended_at, COALESCE(t.user_title, t.title),
               t.digest, t.actions_json, t.applications_json, t.artifacts_json, t.last_state,
               t.event_count, t.pinned, t.grouping_confidence, t.grouping_reasons_json,
               t.is_open, t.is_user_locked,
               w.id, w.kind, w.canonical_key, w.display_name, w.user_confirmed
        FROM task_episodes_v2 t
        LEFT JOIN workstreams w ON w.id = t.workstream_id
        """
    }

    private func queryTasks(_ sql: String, values: [SQLValue] = []) throws -> [TaskMemory] {
        var tasks: [TaskMemory] = []
        try withStatement(sql, values: values) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { tasks.append(decodeTask(statement)) }
        }
        return tasks
    }

    private func decodeTask(_ statement: OpaquePointer) -> TaskMemory {
        let workstream = sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : decodeWorkstream(statement, offset: 16)
        return TaskMemory(
            id: columnText(statement, 0) ?? "unknown", sessionID: columnText(statement, 1) ?? "unknown",
            workstream: workstream, startedAt: dateColumn(statement, 2), endedAt: dateColumn(statement, 3),
            title: columnText(statement, 4) ?? "Untitled task", digest: columnText(statement, 5) ?? "",
            actions: decodeJSON(columnText(statement, 6)), applications: decodeJSON(columnText(statement, 7)),
            artifacts: decodeJSON(columnText(statement, 8)), lastState: columnText(statement, 9),
            eventCount: Int(sqlite3_column_int64(statement, 10)), isPinned: sqlite3_column_int(statement, 11) != 0,
            groupingConfidence: sqlite3_column_double(statement, 12), groupingReasons: decodeJSON(columnText(statement, 13)),
            isOpen: sqlite3_column_int(statement, 14) != 0, isUserLocked: sqlite3_column_int(statement, 15) != 0
        )
    }

    private func decodeWorkstream(_ statement: OpaquePointer, offset: Int32) -> Workstream {
        Workstream(
            id: columnText(statement, offset) ?? "unknown",
            kind: WorkstreamKind(rawValue: columnText(statement, offset + 1) ?? "custom") ?? .custom,
            canonicalKey: columnText(statement, offset + 2) ?? "unknown",
            displayName: columnText(statement, offset + 3) ?? "Untitled",
            userConfirmed: sqlite3_column_int(statement, offset + 4) != 0
        )
    }

    private func decodeEvidence(_ statement: OpaquePointer) -> EvidenceItem {
        EvidenceItem(
            id: columnText(statement, 0) ?? "unknown", taskID: columnText(statement, 1) ?? "unknown",
            observationID: columnText(statement, 2), timestamp: dateColumn(statement, 3),
            kind: columnText(statement, 4) ?? "Unknown", applicationName: columnText(statement, 5) ?? "Unknown",
            excerpt: columnText(statement, 6), url: columnText(statement, 7), documentPath: columnText(statement, 8),
            target: columnText(statement, 9), source: EvidenceSource(rawValue: columnText(statement, 10) ?? "compacted") ?? .compacted,
            priority: Int(sqlite3_column_int64(statement, 11)), redactionPolicyVersion: Int(sqlite3_column_int64(statement, 12))
        )
    }

    private func filteredRecentTasks(_ query: MemoryQuery) throws -> [TaskMemory] {
        let filter = taskFilterSQL(query, alias: "t", includeWhere: true)
        return try queryTasks(
            "\(taskSelectSQL) \(filter.sql) ORDER BY t.ended_at DESC LIMIT ?",
            values: filter.values + [.int(min(max(query.limit, 1), 50))]
        )
    }

    private func taskFilterSQL(_ query: MemoryQuery, alias: String, includeWhere: Bool = false) -> (sql: String, values: [SQLValue]) {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let from = query.from { clauses.append("\(alias).ended_at >= ?"); values.append(.double(from.timeIntervalSince1970)) }
        if let to = query.to { clauses.append("\(alias).started_at <= ?"); values.append(.double(to.timeIntervalSince1970)) }
        if let app = query.application, !app.isEmpty {
            clauses.append("instr(lower(\(alias).applications_json), lower(?)) > 0")
            values.append(.text(app))
        }
        if let workstream = query.workstream, !workstream.isEmpty {
            clauses.append("(instr(lower(w.canonical_key), lower(?)) > 0 OR instr(lower(w.display_name), lower(?)) > 0)")
            values.append(.text(workstream)); values.append(.text(workstream))
        }
        if query.pinnedOnly { clauses.append("\(alias).pinned = 1") }
        guard !clauses.isEmpty else { return (includeWhere ? "" : "", values) }
        return ((includeWhere ? "WHERE " : " AND ") + clauses.joined(separator: " AND "), values)
    }

    // MARK: - Lifecycle and retention

    private func closeOpenSpans(sessionID: String, at date: Date) throws {
        try withStatement(
            "UPDATE activity_spans SET ended_at = MAX(ended_at, ?), is_open = 0 WHERE session_id = ? AND is_open = 1",
            values: [.double(date.timeIntervalSince1970), .text(sessionID)]
        ) { try stepDone($0) }
    }

    private func closeSession(_ id: String, at date: Date) throws {
        try closeOpenSpans(sessionID: id, at: date)
        try withStatement(
            "UPDATE task_episodes_v2 SET ended_at = MAX(ended_at, ?), is_open = 0 WHERE session_id = ? AND is_open = 1",
            values: [.double(date.timeIntervalSince1970), .text(id)]
        ) { try stepDone($0) }
        try withStatement(
            "UPDATE work_sessions SET ended_at = MAX(ended_at, ?), is_open = 0 WHERE id = ?",
            values: [.double(date.timeIntervalSince1970), .text(id)]
        ) { try stepDone($0) }
    }

    private func closeStaleState(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.sessionIdleSeconds).timeIntervalSince1970
        let sessions = try stringColumn("SELECT id FROM work_sessions WHERE is_open = 1 AND last_observation_at < ?", values: [.double(cutoff)])
        for id in sessions {
            let last = try scalarDouble("SELECT last_observation_at FROM work_sessions WHERE id = ?", values: [.text(id)]) ?? cutoff
            try closeSession(id, at: Date(timeIntervalSince1970: last))
        }
    }

    private func pruneExpiredObservations(now: Date) throws {
        guard let days = rawRetentionDays else { return }
        let cutoff = now.addingTimeInterval(TimeInterval(-days * 86_400)).timeIntervalSince1970
        try withStatement("DELETE FROM observations WHERE timestamp < ?", values: [.double(cutoff)]) { try stepDone($0) }
        try execute("UPDATE evidence_items SET observation_id = NULL, source = 'compacted' WHERE observation_id IS NULL")
    }

    // MARK: - Deterministic derivation

    private static func action(for kind: String) -> String {
        switch kind {
        case CapturedEvent.Kind.keyboard.rawValue: "typed"
        case CapturedEvent.Kind.terminal.rawValue: "used terminal"
        case CapturedEvent.Kind.browser.rawValue: "browsed"
        case CapturedEvent.Kind.document.rawValue: "worked with documents"
        case CapturedEvent.Kind.selection.rawValue: "selected content"
        case CapturedEvent.Kind.mouse.rawValue: "interacted"
        case CapturedEvent.Kind.axDiff.rawValue: "reviewed changed content"
        default: "navigated"
        }
    }

    private static func lastState(for observation: Observation) -> String? {
        observation.detail ?? observation.documentPath ?? observation.url ?? observation.windowTitle
    }

    private static func digest(
        workstream: Workstream?, applications: [String], actions: [String], artifacts: [String], lastState: String?
    ) -> String {
        let subject = workstream.map { " on \($0.displayName)" } ?? ""
        let appText = applications.prefix(4).joined(separator: ", ")
        let actionText = actions.prefix(4).joined(separator: ", ")
        let artifactText = artifacts.first.map { " Primary artifact: \($0)." } ?? ""
        let stateText = lastState.map { " Last state: \(String($0.prefix(300)))." } ?? ""
        return "Worked\(subject) using \(appText). Actions: \(actionText).\(artifactText)\(stateText)"
    }

    private static func evidenceSelection(for observation: Observation) -> (priority: Int, excerpt: String?) {
        switch observation.kind {
        case CapturedEvent.Kind.document.rawValue, CapturedEvent.Kind.browser.rawValue:
            return (90, observation.documentPath ?? observation.url ?? observation.detail)
        case CapturedEvent.Kind.terminal.rawValue:
            return (80, observation.detail ?? observation.axText)
        case CapturedEvent.Kind.selection.rawValue, CapturedEvent.Kind.keyboard.rawValue:
            return (70, observation.detail ?? observation.axText)
        case CapturedEvent.Kind.axDiff.rawValue:
            return (60, observation.axText ?? observation.detail)
        case CapturedEvent.Kind.application.rawValue, CapturedEvent.Kind.window.rawValue:
            return (40, observation.windowTitle ?? observation.detail)
        default:
            return (0, nil)
        }
    }

    private static func embeddingText(for task: TaskMemory, evidence: [EvidenceItem]) -> String {
        [
            task.title, task.digest, task.workstream?.canonicalKey,
            task.actions.joined(separator: " "), task.applications.joined(separator: " "),
            task.artifacts.joined(separator: " "), evidence.compactMap(\.excerpt).joined(separator: "\n"),
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private static func isCommunicationApp(_ bundleID: String, name: String) -> Bool {
        let value = "\(bundleID) \(name)".lowercased()
        return ["whatsapp", "slack", "discord", "messages", "telegram", "signal"].contains(where: value.contains)
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func ftsQuery(from query: String) -> String? {
        let terms = query.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init).filter { !$0.isEmpty }.prefix(16)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String) throws {
        guard let database else { throw ContextStoreError.unavailable("The V2 database is not open.") }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw ContextStoreError.sqlite(detail)
        }
    }

    private func withStatement<T>(_ sql: String, values: [SQLValue] = [], body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw ContextStoreError.unavailable("The V2 database is not open.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContextStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, index: Int32(offset + 1), statement: statement) }
        return try body(statement)
    }

    private func bind(_ value: SQLValue, index: Int32, statement: OpaquePointer) {
        switch value {
        case let .text(value): sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        case let .int(value): sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let .double(value): sqlite3_bind_double(statement, index, value)
        case let .blob(value):
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
            }
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ContextStoreError.sqlite(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite statement failed.")
        }
    }

    private func scalarInt(_ sql: String, values: [SQLValue] = []) throws -> Int {
        var value = 0
        try withStatement(sql, values: values) { if sqlite3_step($0) == SQLITE_ROW { value = Int(sqlite3_column_int64($0, 0)) } }
        return value
    }

    private func scalarDouble(_ sql: String, values: [SQLValue] = []) throws -> Double? {
        var value: Double?
        try withStatement(sql, values: values) { if sqlite3_step($0) == SQLITE_ROW { value = sqlite3_column_double($0, 0) } }
        return value
    }

    private func scalarText(_ sql: String, values: [SQLValue] = []) throws -> String? {
        var value: String?
        try withStatement(sql, values: values) { if sqlite3_step($0) == SQLITE_ROW { value = columnText($0, 0) } }
        return value
    }

    private func stringColumn(_ sql: String, values: [SQLValue] = []) throws -> [String] {
        var output: [String] = []
        try withStatement(sql, values: values) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { if let value = columnText(statement, 0) { output.append(value) } }
        }
        return output
    }

    private func stringRows(_ sql: String, values: [SQLValue], columns: Int) throws -> [[String?]] {
        var output: [[String?]] = []
        try withStatement(sql, values: values) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                output.append((0..<columns).map { columnText(statement, Int32($0)) })
            }
        }
        return output
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        var found = false
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if columnText(statement, 1) == column { found = true }
            }
        }
        return found
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func dateColumn(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func encodeJSON(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private func decodeJSON(_ value: String?) -> [String] {
        guard let value, let data = value.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    private func applyPrivateFilePermissions() {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
        where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
