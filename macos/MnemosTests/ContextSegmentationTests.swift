import Foundation
import SQLite3
import XCTest
@testable import Mnemos

final class ContextSegmentationTests: XCTestCase {
    func testContextPreparationRetriesAfterTransientStartupFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemos-retry-\(UUID().uuidString)", isDirectory: true)
        let blockedParent = root.appendingPathComponent("blocked", isDirectory: true)
        let database = blockedParent.appendingPathComponent("fixture.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = ContextEngineStore(databaseURL: database)
        do {
            try await context.prepare()
            XCTFail("Preparation should fail while the database parent is a file.")
        } catch {
            // The next attempt must be allowed to retry after the transient failure.
        }

        try FileManager.default.removeItem(at: blockedParent)
        let legacy = SQLiteMemoryStore(databaseURL: database)
        try await legacy.record(event(
            at: .now, app: "Fixture App", bundle: "dev.fixture.retry", window: "Retry fixture"
        ))
        try await context.prepare()

        let tasks = try await context.recentTasks(limit: 10)
        XCTAssertEqual(tasks.count, 1)
        await context.shutdownForTesting()
        await legacy.shutdownForTesting()
    }

    func testCrossApplicationProjectWorkAndCommunicationInterruption() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let repository = try fixture.makeRepository(owner: "acme", name: "widget")
        let start = Date.now

        try await fixture.record(event(
            at: start, app: "Ghostty", bundle: "com.mitchellh.ghostty",
            window: "widget", path: repository.path, detail: "swift build"
        ))
        try await fixture.record(event(
            at: start.addingTimeInterval(20), app: "Google Chrome", bundle: "com.google.Chrome",
            window: "acme/widget", url: "https://github.com/acme/widget", detail: "Reviewed issue"
        ))
        try await fixture.record(event(
            at: start.addingTimeInterval(40), app: "WhatsApp", bundle: "net.whatsapp.WhatsApp",
            window: "Team chat", detail: "Unrelated message"
        ))
        try await fixture.record(event(
            at: start.addingTimeInterval(55), app: "Ghostty", bundle: "com.mitchellh.ghostty",
            window: "widget", path: repository.path, detail: "swift test"
        ))

        let tasks = try await fixture.context.recentTasks(limit: 20)
        XCTAssertEqual(tasks.count, 2, "Repository work should resume around an explicit communication interruption.")
        let project = try XCTUnwrap(tasks.first(where: { $0.workstream?.canonicalKey == "github.com/acme/widget" }))
        XCTAssertEqual(project.workstream?.kind, .gitRepository)
        XCTAssertNotEqual(project.id, tasks.first(where: { $0.workstream == nil })?.id)

        try await fixture.context.renameTask(id: project.id, title: "Ship widget V2")
        try await fixture.record(event(
            at: start.addingTimeInterval(70), app: "Google Chrome", bundle: "com.google.Chrome",
            window: "acme/widget", url: "https://github.com/acme/widget", detail: "Read pull request"
        ))
        let renamed = try await fixture.context.task(id: project.id)
        XCTAssertEqual(renamed?.title, "Ship widget V2")
        XCTAssertTrue(renamed?.isUserLocked == true)
        await fixture.shutdown()
    }

    func testBrowserURLMisreportedAsDocumentPathUsesHostWorkstream() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.record(event(
            at: .now, app: "Google Chrome", bundle: "com.google.Chrome",
            window: "Pull request", path: "/https:/github.com/acme/widget/pull/12"
        ))
        let tasks = try await fixture.context.recentTasks(limit: 5)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.workstream?.kind, .gitRepository)
        XCTAssertEqual(task.workstream?.canonicalKey, "github.com/acme/widget")
        XCTAssertEqual(task.workstream?.displayName, "widget")
        await fixture.shutdown()
    }

    func testSessionClosesOnPauseAndIdle() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        try await fixture.record(event(at: start, app: "Notes", bundle: "com.apple.Notes", window: "Plan"))
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(30), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
        ))
        try await fixture.record(event(at: start.addingTimeInterval(60), app: "Notes", bundle: "com.apple.Notes", window: "Plan"))
        try await fixture.record(event(at: start.addingTimeInterval(1_000), app: "Notes", bundle: "com.apple.Notes", window: "Plan"))

        let sessions = try await fixture.context.recentSessions(limit: 10)
        XCTAssertEqual(sessions.count, 3, "Pause and a gap beyond 15 minutes must each begin a new session.")
        XCTAssertEqual(sessions.filter(\.isOpen).count, 1)
        await fixture.shutdown()
    }

    func testCandidateCapAndExpiryCreateNewTasks() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        for index in 0..<9 {
            try await fixture.record(event(
                at: start.addingTimeInterval(Double(index)), app: "App \(index)",
                bundle: "dev.fixture.app\(index)", window: "Window \(index)"
            ))
        }
        try await fixture.record(event(
            at: start.addingTimeInterval(10), app: "App 0", bundle: "dev.fixture.app0", window: "Window 0"
        ))
        let cappedTaskCount = try await fixture.context.recentTasks(limit: 30).count
        XCTAssertEqual(cappedTaskCount, 10, "A task outside the eight-entry MRU set must not be reattached.")

        for minute in [10, 20, 29] {
            try await fixture.record(event(
                at: start.addingTimeInterval(Double(minute * 60)), app: "Keepalive",
                bundle: "dev.fixture.keepalive", window: "Ongoing"
            ))
        }
        let beforeExpiryReturn = try await fixture.context.recentTasks(limit: 50).count
        try await fixture.record(event(
            at: start.addingTimeInterval(31 * 60), app: "App 8", bundle: "dev.fixture.app8", window: "Window 8"
        ))
        let afterExpiryReturn = try await fixture.context.recentTasks(limit: 50).count
        XCTAssertGreaterThan(afterExpiryReturn, beforeExpiryReturn)
        await fixture.shutdown()
    }

    func testExcludedSourcesAndSecretsNeverReachSearchableStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        try await fixture.record(event(
            at: start, app: "Google Chrome", bundle: "com.google.Chrome", window: "Incognito"
        ))
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .keyboard, applicationName: "Browser", bundleID: "dev.fixture.browser",
            windowTitle: "Login", target: CapturedTarget(
                role: "AXSecureTextField", subrole: nil, title: "Password", identifier: "password"
            ), detail: "do-not-store"
        ))
        let excludedHealth = await fixture.legacy.health()
        XCTAssertEqual(excludedHealth.observationCount, 0)

        let secret = "fixture-super-secret-value"
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(1), kind: .terminal,
            applicationName: "Ghostty", bundleID: "com.mitchellh.ghostty",
            windowTitle: "Security fixture", detail: "password=\(secret) Authorization: Bearer abc.def.ghi"
        ))
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(2), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
        ))

        for _ in 0..<50 {
            let tasks = try await fixture.context.recentTasks(limit: 10)
            if let task = tasks.first(where: { $0.title.contains("Security fixture") }),
               !(try await fixture.context.evidence(for: task.id)).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let search = try await fixture.context.search(MemoryQuery(text: "fixture-super-secret-value", limit: 10))
        let returnedText = search.flatMap { result in
            [result.task.title, result.task.digest] + result.highlights
                + result.evidencePreviews.compactMap(\.excerpt)
        }.joined(separator: " ")
        XCTAssertFalse(returnedText.contains(secret))

        await fixture.shutdown()
        let searchableText = try fixture.allSearchableText()
        XCTAssertFalse(searchableText.contains(secret))
        XCTAssertFalse(searchableText.contains("abc.def.ghi"))
        XCTAssertTrue(searchableText.contains("[REDACTED]"))
    }

    func testTaskDeletionRemovesRawLegacyFTSAndVectorCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let needle = "deletion-fixture-needle"
        let start = Date.now
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .terminal, applicationName: "Ghostty",
            bundleID: "com.mitchellh.ghostty", windowTitle: "Deletion fixture", detail: needle
        ))
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(1), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
        ))

        var target: TaskMemory?
        for _ in 0..<100 {
            target = try await fixture.context.recentTasks(limit: 10)
                .first(where: { $0.title.contains("Deletion fixture") })
            if let target, !(try await fixture.context.evidence(for: target.id)).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let task = try XCTUnwrap(target)
        try await fixture.context.deleteTask(id: task.id)
        let deletedTask = try await fixture.context.task(id: task.id)
        let legacyMatches = try await fixture.legacy.search(needle, limit: 10)
        XCTAssertNil(deletedTask)
        XCTAssertTrue(legacyMatches.isEmpty)

        await fixture.shutdown()
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM task_episodes_v2 WHERE id = ?", task.id), 0)
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM evidence_items WHERE task_id = ?", task.id), 0)
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM episode_embeddings WHERE task_id = ?", task.id), 0)
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM task_v2_fts WHERE task_id = ?", task.id), 0)
        XCTAssertFalse(try fixture.allSearchableText().contains(needle))
    }

    func testMigrationRestartAssignsEveryObservationExactlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        for index in 0..<12 {
            try await fixture.legacy.record(event(
                at: start.addingTimeInterval(Double(index)), app: "Fixture App",
                bundle: "dev.fixture.migration", window: "Migration \(index % 3)"
            ))
        }
        try await fixture.context.prepare()
        await fixture.context.shutdownForTesting()
        await fixture.legacy.shutdownForTesting()

        let resumed = ContextEngineStore(databaseURL: fixture.database)
        try await resumed.prepare()
        await resumed.shutdownForTesting()

        XCTAssertEqual(try fixture.count("SELECT count(*) FROM observations"), 12)
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM span_observations"), 12)
        XCTAssertEqual(try fixture.count("SELECT count(DISTINCT observation_id) FROM span_observations"), 12)
        XCTAssertEqual(try fixture.count("SELECT count(*) FROM pragma_foreign_key_check"), 0)
    }

    func testCapturePersistenceP95StaysBelowTwentyMilliseconds() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        var durations: [Double] = []
        for index in 0..<250 {
            let began = CFAbsoluteTimeGetCurrent()
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(Double(index) / 10), kind: .keyboard,
                applicationName: "Fixture Editor", bundleID: "dev.fixture.editor",
                windowTitle: "Performance fixture", detail: "semantic chunk \(index)"
            ))
            durations.append((CFAbsoluteTimeGetCurrent() - began) * 1_000)
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        XCTAssertLessThan(p95, 20, "Capture persistence p95 was \(p95) ms")
        await fixture.shutdown()
    }

    func testFilteredFTSSearchWorksWithoutEmbeddings() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .terminal, applicationName: "Ghostty",
            bundleID: "com.mitchellh.ghostty", windowTitle: "Search fixture",
            detail: "compile frobnicator module"
        ))
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(1), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
        ))
        for _ in 0..<50 {
            let results = try await fixture.context.search(MemoryQuery(text: "frobnicator", limit: 10))
            if !results.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await fixture.context.setSemanticSearchEnabled(false)
        let matching = try await fixture.context.search(MemoryQuery(
            text: "frobnicator", application: "Ghostty", limit: 10
        ))
        let excluded = try await fixture.context.search(MemoryQuery(
            text: "frobnicator", application: "Safari", limit: 10
        ))
        XCTAssertEqual(matching.first?.task.title, "Search fixture")
        XCTAssertTrue(matching.first?.matchReasons.contains("lexical") == true)
        XCTAssertTrue(excluded.isEmpty)
        try await fixture.context.setSemanticSearchEnabled(true)
        await fixture.shutdown()
    }

    func testWorkstreamSummariesCountTasksAndFollowDeletions() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let repository = try fixture.makeRepository(owner: "acme", name: "widget")
        let start = Date.now

        try await fixture.record(event(
            at: start, app: "Ghostty", bundle: "com.mitchellh.ghostty",
            window: "widget", path: repository.path, detail: "swift build"
        ))
        try await fixture.record(event(
            at: start.addingTimeInterval(30), app: "Notes", bundle: "com.apple.Notes", window: "Shopping"
        ))

        let summaries = try await fixture.context.workstreamSummaries()
        let repositorySummary = try XCTUnwrap(
            summaries.first(where: { $0.workstream.canonicalKey == "github.com/acme/widget" })
        )
        XCTAssertEqual(repositorySummary.taskCount, 1)
        XCTAssertNotNil(repositorySummary.lastActivityAt, "A workstream with tasks must report its last activity.")

        let tasks = try await fixture.context.recentTasks(limit: 20)
        let repositoryTask = try XCTUnwrap(
            tasks.first(where: { $0.workstream?.canonicalKey == "github.com/acme/widget" })
        )
        try await fixture.context.deleteTask(id: repositoryTask.id)

        let afterDeletion = try await fixture.context.workstreamSummaries()
        let emptied = try XCTUnwrap(
            afterDeletion.first(where: { $0.workstream.canonicalKey == "github.com/acme/widget" })
        )
        XCTAssertEqual(emptied.taskCount, 0)
        XCTAssertNil(emptied.lastActivityAt, "A workstream that lost every task reports no activity.")
        await fixture.shutdown()
    }

    func testTaskPagingWalksBackwardsWithoutRepeating() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now
        for index in 0..<5 {
            try await fixture.record(event(
                at: start.addingTimeInterval(Double(index)), app: "App \(index)",
                bundle: "dev.fixture.app\(index)", window: "Window \(index)"
            ))
        }

        let all = try await fixture.context.tasks(before: nil, limit: 50)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all, all.sorted { $0.endedAt > $1.endedAt }, "Pages come back newest first.")

        let firstPage = try await fixture.context.tasks(before: nil, limit: 2)
        XCTAssertEqual(firstPage.map(\.id), Array(all.prefix(2).map(\.id)))

        let oldest = try XCTUnwrap(firstPage.last?.endedAt)
        let secondPage = try await fixture.context.tasks(before: oldest, limit: 2)
        XCTAssertEqual(secondPage.map(\.id), Array(all.dropFirst(2).prefix(2).map(\.id)))
        XCTAssertTrue(
            Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))),
            "Paging must not repeat a task across pages."
        )
        await fixture.shutdown()
    }
}

private extension ContextSegmentationTests {
    final class Fixture: @unchecked Sendable {
        let directory: URL
        let database: URL
        let legacy: SQLiteMemoryStore
        let context: ContextEngineStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mnemos-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = directory.appendingPathComponent("fixture.sqlite")
            legacy = SQLiteMemoryStore(databaseURL: database)
            context = ContextEngineStore(databaseURL: database)
        }

        func record(_ event: CapturedEvent) async throws {
            try await legacy.record(event)
            try await context.record(event)
        }

        func makeRepository(owner: String, name: String) throws -> URL {
            let repository = directory.appendingPathComponent(name, isDirectory: true)
            let git = repository.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            let config = "[remote \"origin\"]\n\turl = git@github.com:\(owner)/\(name).git\n"
            try config.write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
            return repository
        }

        func shutdown() async {
            await context.shutdownForTesting()
            await legacy.shutdownForTesting()
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: directory)
        }

        func allSearchableText() throws -> String {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let handle else { throw NSError(domain: "MnemosTests", code: 1) }
            defer { sqlite3_close(handle) }
            let sql = """
            SELECT value FROM (
                SELECT COALESCE(window_title,'') || ' ' || COALESCE(document_path,'') || ' ' ||
                       COALESCE(url,'') || ' ' || COALESCE(detail,'') || ' ' || COALESCE(ax_text,'') AS value
                FROM observations
                UNION ALL SELECT COALESCE(excerpt,'') || ' ' || COALESCE(url,'') || ' ' ||
                       COALESCE(document_path,'') || ' ' || COALESCE(target,'') FROM evidence_items
                UNION ALL SELECT title || ' ' || digest || ' ' || evidence FROM task_v2_fts
            )
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "MnemosTests", code: 2) }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
            return values.joined(separator: "\n")
        }

        func count(_ sql: String, _ argument: String) throws -> Int {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let handle else { throw NSError(domain: "MnemosTests", code: 3) }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "MnemosTests", code: 4) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "MnemosTests", code: 5) }
            return Int(sqlite3_column_int64(statement, 0))
        }


        func count(_ sql: String) throws -> Int {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let handle else { throw NSError(domain: "MnemosTests", code: 6) }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "MnemosTests", code: 7) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "MnemosTests", code: 8) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func event(
        at timestamp: Date,
        app: String,
        bundle: String,
        window: String,
        path: String? = nil,
        url: String? = nil,
        detail: String? = nil
    ) -> CapturedEvent {
        CapturedEvent(
            timestamp: timestamp, kind: path != nil ? .document : (url != nil ? .browser : .window),
            applicationName: app, bundleID: bundle, windowTitle: window,
            documentPath: path, url: url, detail: detail
        )
    }
}
