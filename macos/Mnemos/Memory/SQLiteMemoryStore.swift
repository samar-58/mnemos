import Foundation
import SQLite3

private enum MemoryStoreError: LocalizedError {
    case unavailable(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .sqlite(message): message
        }
    }
}

actor SQLiteMemoryStore {
    private struct OpenEpisode {
        let episode: MemoryEpisode
        let lastObservationAt: Date
    }

    private var database: OpaquePointer?
    private var startupError: String?
    private let databaseURL: URL
    private let rawRetentionDays = 30

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
            return
        }
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mnemos", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("mnemos.sqlite", isDirectory: false)
    }

    private func prepareIfNeeded() throws {
        if database != nil { return }
        if let startupError { throw MemoryStoreError.unavailable(startupError) }
        let fileManager = FileManager.default
        let root = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
                  let handle else {
                let message = handle.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) }
                    ?? "Unable to open the Mnemos database."
                if let handle { sqlite3_close(handle) }
                throw MemoryStoreError.sqlite(message)
            }
            database = handle
            try configureDatabase()
            try migrateDatabase()
            try closeStaleEpisodes(now: .now)
            try pruneExpiredObservations(now: .now)
            applyPrivateFilePermissions()
        } catch {
            startupError = error.localizedDescription
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }

    func record(_ event: CapturedEvent) throws {
        guard let event = CapturePrivacy.sanitizedEvent(event) else { return }
        try prepareIfNeeded()

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let episodeID = try episodeID(for: event)
            try insertObservation(event, episodeID: episodeID)
            try updateEpisode(episodeID, with: event)
            if event.kind == .session, event.detail?.localizedCaseInsensitiveContains("paused") == true {
                try closeEpisode(episodeID, at: event.timestamp)
            }
            try execute("COMMIT")
            applyPrivateFilePermissions()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func shutdownForTesting() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    func health() -> MemoryStoreHealth {
        do {
            try prepareIfNeeded()
        } catch {
            return MemoryStoreHealth(
                state: .unavailable(error.localizedDescription),
                observationCount: 0,
                episodeCount: 0
            )
        }
        do {
            return MemoryStoreHealth(
                state: .ready,
                observationCount: try scalarInt("SELECT COUNT(*) FROM observations"),
                episodeCount: try scalarInt("SELECT COUNT(*) FROM episodes")
            )
        } catch {
            return MemoryStoreHealth(state: .unavailable(error.localizedDescription), observationCount: 0, episodeCount: 0)
        }
    }

    func recentEpisodes(limit: Int = 20) throws -> [MemoryEpisode] {
        try prepareIfNeeded()
        return try queryEpisodes(
            """
            SELECT id, started_at, ended_at, title, summary, project_key, applications_json,
                   artifacts_json, last_state, event_count, importance, is_open
            FROM episodes
            ORDER BY ended_at DESC
            LIMIT ?
            """,
            bind: { statement in sqlite3_bind_int(statement, 1, Int32(clamping: limit)) }
        )
    }

    func search(_ query: String, limit: Int = 10) throws -> [MemorySearchResult] {
        try prepareIfNeeded()
        guard let matchQuery = Self.ftsQuery(from: query) else {
            return try recentEpisodes(limit: limit).map {
                MemorySearchResult(episode: $0, score: Self.rank(episode: $0, lexical: 0), highlights: [])
            }
        }

        var results: [String: MemorySearchResult] = [:]
        try withStatement(
            """
            SELECT e.id, e.started_at, e.ended_at, e.title, e.summary, e.project_key,
                   e.applications_json, e.artifacts_json, e.last_state, e.event_count,
                   e.importance, e.is_open, bm25(episode_fts, 4.0, 2.0, 1.5, 1.0),
                   snippet(episode_fts, 1, '‹', '›', '…', 24)
            FROM episode_fts
            JOIN episodes e ON e.rowid = episode_fts.rowid
            WHERE episode_fts MATCH ?
            ORDER BY bm25(episode_fts, 4.0, 2.0, 1.5, 1.0)
            LIMIT ?
            """
        ) { statement in
            bindText(matchQuery, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(clamping: max(limit * 3, 20)))
            while sqlite3_step(statement) == SQLITE_ROW {
                let episode = decodeEpisode(statement, startingAt: 0)
                let lexical = max(0, -sqlite3_column_double(statement, 12))
                let highlight = columnText(statement, 13)
                results[episode.id] = MemorySearchResult(
                    episode: episode,
                    score: Self.rank(episode: episode, lexical: lexical),
                    highlights: highlight.map { [$0] } ?? []
                )
            }
        }

        try withStatement(
            """
            SELECT e.id, e.started_at, e.ended_at, e.title, e.summary, e.project_key,
                   e.applications_json, e.artifacts_json, e.last_state, e.event_count,
                   e.importance, e.is_open, bm25(observation_fts, 3.0, 1.5, 1.2, 1.2, 1.0, 1.0),
                   snippet(observation_fts, 0, '‹', '›', '…', 28)
            FROM observation_fts
            JOIN observations o ON o.rowid = observation_fts.rowid
            JOIN episodes e ON e.id = o.episode_id
            WHERE observation_fts MATCH ?
            ORDER BY bm25(observation_fts, 3.0, 1.5, 1.2, 1.2, 1.0, 1.0)
            LIMIT ?
            """
        ) { statement in
            bindText(matchQuery, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(clamping: max(limit * 5, 40)))
            while sqlite3_step(statement) == SQLITE_ROW {
                let episode = decodeEpisode(statement, startingAt: 0)
                let lexical = max(0, -sqlite3_column_double(statement, 12))
                let highlight = columnText(statement, 13)
                let score = Self.rank(episode: episode, lexical: lexical)
                if var existing = results[episode.id] {
                    var highlights = existing.highlights
                    if let highlight, !highlights.contains(highlight), highlights.count < 3 {
                        highlights.append(highlight)
                    }
                    existing = MemorySearchResult(
                        episode: existing.episode,
                        score: max(existing.score, score) + min(score, existing.score) * 0.15,
                        highlights: highlights
                    )
                    results[episode.id] = existing
                } else {
                    results[episode.id] = MemorySearchResult(
                        episode: episode,
                        score: score,
                        highlights: highlight.map { [$0] } ?? []
                    )
                }
            }
        }

        return Array(results.values)
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.episode.endedAt > rhs.episode.endedAt }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    func evidence(for episodeID: String, limit: Int = 100) throws -> [EpisodeEvidence] {
        try prepareIfNeeded()
        var evidence: [EpisodeEvidence] = []
        try withStatement(
            """
            SELECT id, timestamp, kind, application_name, window_title, url, document_path,
                   target_role, target_title, target_identifier, detail
            FROM observations
            WHERE episode_id = ?
            ORDER BY timestamp DESC
            LIMIT ?
            """
        ) { statement in
            bindText(episodeID, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(clamping: limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                let target = [columnText(statement, 7), columnText(statement, 8), columnText(statement, 9)]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                evidence.append(
                    EpisodeEvidence(
                        id: columnText(statement, 0) ?? UUID().uuidString,
                        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        kind: columnText(statement, 2) ?? "Unknown",
                        applicationName: columnText(statement, 3) ?? "Unknown",
                        windowTitle: columnText(statement, 4),
                        url: columnText(statement, 5),
                        documentPath: columnText(statement, 6),
                        target: target.isEmpty ? nil : target,
                        detail: columnText(statement, 10)
                    )
                )
            }
        }
        return evidence.reversed()
    }

    func episode(id: String) throws -> MemoryEpisode? {
        try prepareIfNeeded()
        return try episode(withID: id)
    }

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    private func migrateDatabase() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """
        )
        let version = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        guard version < 1 else { return }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute(
                """
                CREATE TABLE episodes (
                    id TEXT NOT NULL UNIQUE,
                    started_at REAL NOT NULL,
                    ended_at REAL NOT NULL,
                    last_observation_at REAL NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    project_key TEXT,
                    applications_json TEXT NOT NULL DEFAULT '[]',
                    artifacts_json TEXT NOT NULL DEFAULT '[]',
                    last_state TEXT,
                    event_count INTEGER NOT NULL DEFAULT 0,
                    importance REAL NOT NULL DEFAULT 0,
                    is_open INTEGER NOT NULL DEFAULT 1
                )
                """
            )
            try execute("CREATE INDEX episodes_ended_at_idx ON episodes(ended_at DESC)")
            try execute("CREATE INDEX episodes_project_key_idx ON episodes(project_key, ended_at DESC)")

            try execute(
                """
                CREATE TABLE observations (
                    id TEXT NOT NULL UNIQUE,
                    timestamp REAL NOT NULL,
                    kind TEXT NOT NULL,
                    application_name TEXT NOT NULL,
                    bundle_id TEXT NOT NULL,
                    window_title TEXT,
                    document_path TEXT,
                    url TEXT,
                    target_role TEXT,
                    target_subrole TEXT,
                    target_title TEXT,
                    target_identifier TEXT,
                    detail TEXT,
                    ax_text TEXT,
                    fingerprint TEXT NOT NULL,
                    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE
                )
                """
            )
            try execute("CREATE INDEX observations_timestamp_idx ON observations(timestamp DESC)")
            try execute("CREATE INDEX observations_episode_idx ON observations(episode_id, timestamp)")
            try execute("CREATE INDEX observations_app_idx ON observations(bundle_id, timestamp DESC)")
            try execute("CREATE INDEX observations_fingerprint_idx ON observations(fingerprint, timestamp DESC)")

            try execute(
                """
                CREATE VIRTUAL TABLE observation_fts USING fts5(
                    detail, ax_text, window_title, document_path, url, target_title,
                    content='observations', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                )
                """
            )
            try execute(
                """
                CREATE TRIGGER observations_ai AFTER INSERT ON observations BEGIN
                    INSERT INTO observation_fts(rowid, detail, ax_text, window_title, document_path, url, target_title)
                    VALUES (new.rowid, new.detail, new.ax_text, new.window_title, new.document_path, new.url, new.target_title);
                END
                """
            )
            try execute(
                """
                CREATE TRIGGER observations_ad AFTER DELETE ON observations BEGIN
                    INSERT INTO observation_fts(observation_fts, rowid, detail, ax_text, window_title, document_path, url, target_title)
                    VALUES ('delete', old.rowid, old.detail, old.ax_text, old.window_title, old.document_path, old.url, old.target_title);
                END
                """
            )

            try execute(
                """
                CREATE VIRTUAL TABLE episode_fts USING fts5(
                    title, summary, project_key, last_state,
                    content='episodes', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                )
                """
            )
            try execute(
                """
                CREATE TRIGGER episodes_ai AFTER INSERT ON episodes BEGIN
                    INSERT INTO episode_fts(rowid, title, summary, project_key, last_state)
                    VALUES (new.rowid, new.title, new.summary, new.project_key, new.last_state);
                END
                """
            )
            try execute(
                """
                CREATE TRIGGER episodes_ad AFTER DELETE ON episodes BEGIN
                    INSERT INTO episode_fts(episode_fts, rowid, title, summary, project_key, last_state)
                    VALUES ('delete', old.rowid, old.title, old.summary, old.project_key, old.last_state);
                END
                """
            )
            try execute(
                """
                CREATE TRIGGER episodes_au AFTER UPDATE ON episodes BEGIN
                    INSERT INTO episode_fts(episode_fts, rowid, title, summary, project_key, last_state)
                    VALUES ('delete', old.rowid, old.title, old.summary, old.project_key, old.last_state);
                    INSERT INTO episode_fts(rowid, title, summary, project_key, last_state)
                    VALUES (new.rowid, new.title, new.summary, new.project_key, new.last_state);
                END
                """
            )

            try withStatement("INSERT INTO schema_migrations(version, applied_at) VALUES (1, ?)") { statement in
                sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func episodeID(for event: CapturedEvent) throws -> String {
        let projectKey = Self.projectKey(for: event)
        if let open = try latestOpenEpisode() {
            let gap = event.timestamp.timeIntervalSince(open.lastObservationAt)
            let duration = event.timestamp.timeIntervalSince(open.episode.startedAt)
            let projectChanged = open.episode.projectKey != nil
                && projectKey != nil
                && open.episode.projectKey != projectKey
                && gap > 30
            if gap <= 180, duration <= 600, !projectChanged {
                return open.episode.id
            }
            try closeEpisode(open.episode.id, at: open.lastObservationAt)
        }

        let id = UUID().uuidString.lowercased()
        let title = Self.episodeTitle(for: event, projectKey: projectKey)
        try withStatement(
            """
            INSERT INTO episodes(
                id, started_at, ended_at, last_observation_at, title, summary, project_key,
                applications_json, artifacts_json, last_state, event_count, importance, is_open
            ) VALUES (?, ?, ?, ?, ?, ?, ?, '[]', '[]', NULL, 0, 0, 1)
            """
        ) { statement in
            bindText(id, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, event.timestamp.timeIntervalSince1970)
            bindText(title, to: 5, in: statement)
            bindText("New activity episode.", to: 6, in: statement)
            bindOptionalText(projectKey, to: 7, in: statement)
            try stepDone(statement)
        }
        return id
    }

    private func insertObservation(_ event: CapturedEvent, episodeID: String) throws {
        try withStatement(
            """
            INSERT OR IGNORE INTO observations(
                id, timestamp, kind, application_name, bundle_id, window_title, document_path,
                url, target_role, target_subrole, target_title, target_identifier, detail,
                ax_text, fingerprint, episode_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bindText(event.id.uuidString.lowercased(), to: 1, in: statement)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
            bindText(event.kind.rawValue, to: 3, in: statement)
            bindText(event.applicationName, to: 4, in: statement)
            bindText(event.bundleID, to: 5, in: statement)
            bindOptionalText(event.windowTitle, to: 6, in: statement)
            bindOptionalText(event.documentPath, to: 7, in: statement)
            bindOptionalText(event.url, to: 8, in: statement)
            bindOptionalText(event.target?.role, to: 9, in: statement)
            bindOptionalText(event.target?.subrole, to: 10, in: statement)
            bindOptionalText(event.target?.title, to: 11, in: statement)
            bindOptionalText(event.target?.identifier, to: 12, in: statement)
            bindOptionalText(event.detail, to: 13, in: statement)
            bindOptionalText(event.axText, to: 14, in: statement)
            bindText(event.fingerprint, to: 15, in: statement)
            bindText(episodeID, to: 16, in: statement)
            try stepDone(statement)
        }
    }

    private func updateEpisode(_ episodeID: String, with event: CapturedEvent) throws {
        guard let episode = try episode(withID: episodeID) else { return }
        var applications = Set(episode.applications)
        applications.insert(event.applicationName)
        var artifacts = Set(episode.artifacts)
        if let documentPath = event.documentPath { artifacts.insert(documentPath) }
        if let url = event.url { artifacts.insert(url) }

        let eventCount = episode.eventCount + 1
        let summary = Self.episodeSummary(
            applications: applications.sorted(),
            eventCount: eventCount,
            latestKind: event.kind.rawValue,
            projectKey: episode.projectKey
        )
        let lastState = Self.lastState(for: event) ?? episode.lastState
        let importance = min(1, episode.importance + Self.importanceIncrement(for: event.kind))

        try withStatement(
            """
            UPDATE episodes
            SET ended_at = ?, last_observation_at = ?, summary = ?, applications_json = ?,
                artifacts_json = ?, last_state = ?, event_count = ?, importance = ?
            WHERE id = ?
            """
        ) { statement in
            sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
            bindText(summary, to: 3, in: statement)
            bindText(encodeJSON(applications.sorted()), to: 4, in: statement)
            bindText(encodeJSON(artifacts.sorted().prefix(40).map { $0 }), to: 5, in: statement)
            bindOptionalText(lastState, to: 6, in: statement)
            sqlite3_bind_int(statement, 7, Int32(clamping: eventCount))
            sqlite3_bind_double(statement, 8, importance)
            bindText(episodeID, to: 9, in: statement)
            try stepDone(statement)
        }
    }

    private func latestOpenEpisode() throws -> OpenEpisode? {
        var result: OpenEpisode?
        try withStatement(
            """
            SELECT id, started_at, ended_at, title, summary, project_key, applications_json,
                   artifacts_json, last_state, event_count, importance, is_open, last_observation_at
            FROM episodes
            WHERE is_open = 1
            ORDER BY last_observation_at DESC
            LIMIT 1
            """
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                result = OpenEpisode(
                    episode: decodeEpisode(statement, startingAt: 0),
                    lastObservationAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
                )
            }
        }
        return result
    }

    private func episode(withID id: String) throws -> MemoryEpisode? {
        var result: MemoryEpisode?
        try withStatement(
            """
            SELECT id, started_at, ended_at, title, summary, project_key, applications_json,
                   artifacts_json, last_state, event_count, importance, is_open
            FROM episodes WHERE id = ? LIMIT 1
            """
        ) { statement in
            bindText(id, to: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                result = decodeEpisode(statement, startingAt: 0)
            }
        }
        return result
    }

    private func closeEpisode(_ id: String, at date: Date) throws {
        try withStatement("UPDATE episodes SET ended_at = MAX(ended_at, ?), is_open = 0 WHERE id = ?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bindText(id, to: 2, in: statement)
            try stepDone(statement)
        }
    }

    private func closeStaleEpisodes(now: Date) throws {
        try withStatement(
            "UPDATE episodes SET is_open = 0 WHERE is_open = 1 AND last_observation_at < ?"
        ) { statement in
            sqlite3_bind_double(statement, 1, now.addingTimeInterval(-180).timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    private func pruneExpiredObservations(now: Date) throws {
        let cutoff = now.addingTimeInterval(TimeInterval(-rawRetentionDays * 86_400))
        try withStatement("DELETE FROM observations WHERE timestamp < ?") { statement in
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    private func queryEpisodes(
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws -> [MemoryEpisode] {
        var episodes: [MemoryEpisode] = []
        try withStatement(sql) { statement in
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                episodes.append(decodeEpisode(statement, startingAt: 0))
            }
        }
        return episodes
    }

    private func decodeEpisode(_ statement: OpaquePointer, startingAt offset: Int32) -> MemoryEpisode {
        MemoryEpisode(
            id: columnText(statement, offset) ?? "unknown",
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 1)),
            endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 2)),
            title: columnText(statement, offset + 3) ?? "Untitled activity",
            summary: columnText(statement, offset + 4) ?? "",
            projectKey: columnText(statement, offset + 5),
            applications: decodeJSON(columnText(statement, offset + 6)),
            artifacts: decodeJSON(columnText(statement, offset + 7)),
            lastState: columnText(statement, offset + 8),
            eventCount: Int(sqlite3_column_int64(statement, offset + 9)),
            importance: sqlite3_column_double(statement, offset + 10),
            isOpen: sqlite3_column_int(statement, offset + 11) != 0
        )
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw MemoryStoreError.unavailable("Database is not open.") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MemoryStoreError.sqlite(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try withStatement(sql) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                value = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return value
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw MemoryStoreError.unavailable("Database is not open.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MemoryStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite statement failed."
            throw MemoryStoreError.sqlite(message)
        }
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bindText(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func encodeJSON(_ strings: [String]) -> String {
        guard let data = try? JSONEncoder().encode(strings),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    private func decodeJSON(_ value: String?) -> [String] {
        guard let value,
              let data = value.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return strings
    }

    private func applyPrivateFilePermissions() {
        let fileManager = FileManager.default
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func projectKey(for event: CapturedEvent) -> String? {
        if let urlString = event.url,
           let url = URL(string: urlString),
           let host = url.host?.lowercased() {
            let components = url.pathComponents.filter { $0 != "/" }
            if host == "github.com", components.count >= 2 {
                return "github.com/\(components[0])/\(components[1])"
            }
            return host
        }
        if let documentPath = event.documentPath {
            let url = URL(fileURLWithPath: documentPath)
            let component = url.pathExtension.isEmpty
                ? url.lastPathComponent
                : url.deletingLastPathComponent().lastPathComponent
            return component.isEmpty ? nil : component
        }
        return nil
    }

    private static func episodeTitle(for event: CapturedEvent, projectKey: String?) -> String {
        if let projectKey {
            let name = projectKey.split(separator: "/").last.map(String.init) ?? projectKey
            return "Working on \(name)"
        }
        if let windowTitle = event.windowTitle, !windowTitle.isEmpty {
            return String(windowTitle.prefix(120))
        }
        return "Activity in \(event.applicationName)"
    }

    private static func episodeSummary(
        applications: [String],
        eventCount: Int,
        latestKind: String,
        projectKey: String?
    ) -> String {
        let appText = applications.prefix(4).joined(separator: ", ")
        let projectText = projectKey.map { " for \($0)" } ?? ""
        return "Used \(appText)\(projectText). Recorded \(eventCount) semantic events; the latest was \(latestKind.lowercased())."
    }

    private static func lastState(for event: CapturedEvent) -> String? {
        switch event.kind {
        case .keyboard:
            return "Typed in \(event.target?.summary ?? event.windowTitle ?? event.applicationName)."
        case .mouse:
            return "\(event.detail ?? "Interacted") with \(event.target?.summary ?? event.windowTitle ?? event.applicationName)."
        case .terminal, .selection:
            return event.detail.map { String($0.prefix(500)) }
        default:
            return event.documentPath ?? event.url ?? event.windowTitle ?? event.detail
        }
    }

    private static func importanceIncrement(for kind: CapturedEvent.Kind) -> Double {
        switch kind {
        case .terminal, .selection, .document, .browser: 0.08
        case .keyboard, .axDiff: 0.03
        case .application, .window, .focus, .mouse, .axSnapshot, .session, .diagnostic: 0.01
        }
    }

    private static func ftsQuery(from query: String) -> String? {
        let terms = query
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(12)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }

    private static func rank(episode: MemoryEpisode, lexical: Double) -> Double {
        let ageDays = max(0, Date.now.timeIntervalSince(episode.endedAt) / 86_400)
        let recency = 1 / (1 + ageDays * 0.12)
        let lexicalSignal = lexical > 0 ? 1 + log1p(lexical * 1_000_000) : 0
        return lexicalSignal * 0.7 + recency * 0.2 + episode.importance * 0.1
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
