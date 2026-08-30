import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Mnemos

final class PersonalContextTests: XCTestCase {
    private var savedCloudEnabled: Any?
    private var savedCloudApps: Any?
    private var savedCloudDomains: Any?

    override func setUp() {
        super.setUp()
        savedCloudEnabled = UserDefaults.standard.object(forKey: PersonalContextStore.cloudEnabledDefaultsKey)
        savedCloudApps = UserDefaults.standard.object(forKey: PersonalContextStore.cloudApplicationDefaultsKey)
        savedCloudDomains = UserDefaults.standard.object(forKey: PersonalContextStore.cloudDomainDefaultsKey)
        UserDefaults.standard.set(false, forKey: PersonalContextStore.cloudEnabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: PersonalContextStore.cloudApplicationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: PersonalContextStore.cloudDomainDefaultsKey)
    }

    override func tearDown() {
        restore(savedCloudEnabled, key: PersonalContextStore.cloudEnabledDefaultsKey)
        restore(savedCloudApps, key: PersonalContextStore.cloudApplicationDefaultsKey)
        restore(savedCloudDomains, key: PersonalContextStore.cloudDomainDefaultsKey)
        super.tearDown()
    }

    func testV3CreatesEvidenceBackedLocalMemoryAndContextPack() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now.addingTimeInterval(-60)
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .terminal, applicationName: "Ghostty",
            bundleID: "com.mitchellh.ghostty", windowTitle: "Mnemos tests",
            detail: "swift test"
        ))
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(2), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
        ))
        try await Task.sleep(for: .milliseconds(50))

        try await fixture.personal.prepare()
        let memories = try await fixture.personal.recentMemories(limit: 10)
        let memory = try XCTUnwrap(memories.first(where: { $0.scope == .episode }))
        XCTAssertEqual(memory.authorship, .deterministic)
        XCTAssertEqual(memory.status, .localOnly)
        XCTAssertTrue(memory.applications.contains("Ghostty"))
        let claims = try await fixture.personal.claims(for: memory.versionID)
        XCTAssertFalse(claims.isEmpty)

        let taskResults = try await fixture.context.search(MemoryQuery(text: "swift test", limit: 5))
        let pack = try await fixture.personal.composeContext(query: "continue tests", results: taskResults)
        XCTAssertEqual(pack.memories.first?.memory.id, memory.id)
        XCTAssertTrue(pack.approvedSkills.isEmpty)
        XCTAssertTrue(pack.trustBoundary.contains("Only user-approved skills"))
        await fixture.shutdown()
    }

    func testLifecycleOnlyActivityNeverBecomesV3Memory() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.record(CapturedEvent(
            timestamp: .now, kind: .session, applicationName: "macOS",
            bundleID: "com.apple.system", detail: "Screen sleep"
        ))
        try await fixture.personal.prepare()
        let memories = try await fixture.personal.recentMemories(limit: 10)
        XCTAssertTrue(memories.isEmpty)
        await fixture.shutdown()
    }

    func testResumeWithoutSupportingEvidenceStoresNullForeignKey() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now.addingTimeInterval(-120)
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .session, applicationName: "macOS",
            bundleID: "com.apple.system", detail: "System sleep"
        ))
        let tasks = try await fixture.context.recentTasks(limit: 5)
        let task = try XCTUnwrap(tasks.first)
        try await fixture.context.setPinned(true, taskID: task.id)
        await fixture.context.shutdownForTesting()
        await fixture.legacy.shutdownForTesting()
        try fixture.executeSQL(
            "UPDATE task_episodes_v2 SET last_state = 'Reviewing release checklist' WHERE id = '\(task.id)'; DELETE FROM evidence_items WHERE task_id = '\(task.id)';"
        )

        try await fixture.personal.prepare()
        let memories = try await fixture.personal.recentMemories(limit: 10)
        let memory = try XCTUnwrap(memories.first { $0.scopeID == task.id })
        XCTAssertEqual(memory.resumeState?.value, "Reviewing release checklist")
        XCTAssertNil(memory.resumeState?.supportingEvidenceID)
        let report = try await fixture.personal.synchronizeDeterministicMemories(limit: 20)
        XCTAssertEqual(report.skipped, 0)
        await fixture.personal.shutdownForTesting()
    }

    func testPinnedAccessibilityLifecycleStateIsNotUsedAsResumeText() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.record(CapturedEvent(
            timestamp: .now.addingTimeInterval(-60), kind: .axSnapshot,
            applicationName: "Finder", bundleID: "com.apple.finder",
            windowTitle: "Finder", detail: "Initial bounded Accessibility tree",
            axText: "- [0] role=AXWindow title=\"Finder\""
        ))
        let tasks = try await fixture.context.recentTasks(limit: 5)
        let task = try XCTUnwrap(tasks.first)
        try await fixture.context.setPinned(true, taskID: task.id)

        try await fixture.personal.prepare()
        let memories = try await fixture.personal.recentMemories(limit: 10)
        let memory = try XCTUnwrap(memories.first { $0.scopeID == task.id })
        XCTAssertNil(memory.resumeState)
        XCTAssertFalse(memory.summary.localizedCaseInsensitiveContains("Accessibility tree"))
        await fixture.shutdown()
    }

    func testRecallIntentResolverUsesLocalCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 30, hour: 10, minute: 30
        )))

        let night = RecallIntentResolver.resolve(
            MemoryQuery(text: "What was I doing last night?"), now: now, calendar: calendar
        )
        XCTAssertEqual(night.intent, .lastNight)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(night.query.from)), 29)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(night.query.from)), 18)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(night.query.to)), 30)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(night.query.to)), 5)
        XCTAssertEqual(night.query.sortOrder, .chronological)

        let morning = RecallIntentResolver.resolve(
            MemoryQuery(text: "What was the first thing I did when the screen opened in the morning?"),
            now: now, calendar: calendar
        )
        XCTAssertEqual(morning.intent, .firstMorningActivity)
        XCTAssertTrue(morning.query.anchorAfterWake)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(morning.query.from)), 5)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(morning.query.to)), 12)

        let day = RecallIntentResolver.resolve(
            MemoryQuery(text: "Summarize my day on 28 August"), now: now, calendar: calendar
        )
        guard case let .calendarDay(parsedDay) = day.intent else {
            return XCTFail("Expected a calendar-day recall intent.")
        }
        XCTAssertEqual(calendar.component(.day, from: parsedDay), 28)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(day.query.from)), 28)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(day.query.to)), 29)
        XCTAssertEqual(day.query.limit, 50)

        let latest = RecallIntentResolver.resolve(
            MemoryQuery(text: "What was I working on last?"), now: now, calendar: calendar
        )
        XCTAssertEqual(latest.intent, .latest)
        XCTAssertEqual(latest.query.limit, 1)
        XCTAssertEqual(latest.query.sortOrder, .recent)
    }

    func testRealShapeFixtureConsolidatesPatternsAndCreatesCandidateSkill() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let repository = fixture.directory.appendingPathComponent("mnemos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let dayOne = Calendar.current.startOfDay(for: .now.addingTimeInterval(-2 * 86_400))
        // The app prepares its stores at launch and captures afterwards. One
        // lifecycle-only event ahead of the fixture window runs the V1 and V2
        // migrations so the backfill and stale-session sweep cannot run in the
        // middle of a stretch of work and split it in two.
        try await fixture.record(CapturedEvent(
            timestamp: dayOne, kind: .session, applicationName: "macOS",
            bundleID: "com.apple.system", detail: "Screen sleep"
        ))
        let starts = [
            dayOne.addingTimeInterval(10 * 3_600),
            dayOne.addingTimeInterval(14 * 3_600),
            dayOne.addingTimeInterval(86_400 + 10 * 3_600),
        ]
        for start in starts {
            try await fixture.record(CapturedEvent(
                timestamp: start, kind: .document, applicationName: "Xcode",
                bundleID: "com.apple.dt.Xcode", windowTitle: "Mnemos",
                documentPath: repository.appendingPathComponent("AppModel.swift").path,
                detail: "Opened AppModel.swift"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(30), kind: .keyboard, applicationName: "Xcode",
                bundleID: "com.apple.dt.Xcode", windowTitle: "Mnemos",
                documentPath: repository.appendingPathComponent("AppModel.swift").path,
                detail: "Edited memory processing"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(60), kind: .session,
                applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
            ))
        }

        var readyTaskCount = 0
        for _ in 0..<100 {
            let tasks = try await fixture.context.recentTasks(limit: 20).filter { $0.workstream != nil }
            var ready = 0
            for task in tasks {
                let evidence = try await fixture.context.evidence(for: task.id)
                if evidence.count >= 2 { ready += 1 }
            }
            readyTaskCount = ready
            if ready >= 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(readyTaskCount, 3, "The realistic fixture must finish compacting evidence.")

        try await fixture.personal.prepare()
        try await fixture.personal.consolidateDay(
            from: dayOne, to: dayOne.addingTimeInterval(86_400)
        )
        try await fixture.personal.minePatterns(now: .now)

        let memories = try await fixture.personal.recentMemories(limit: 100)
        XCTAssertTrue(memories.contains { $0.scope == .dailyWorkstream })
        let patterns = try await fixture.personal.patterns(limit: 20)
        XCTAssertEqual(patterns.first?.occurrenceCount, 3)
        let candidates = try await fixture.personal.skills(status: .candidate, limit: 20)
        XCTAssertEqual(candidates.map(\.id), [WorkingStyleSynthesizer.skillID])
        await fixture.shutdown()
    }

    /// A repeated workflow that never settles on one project still deserves a
    /// candidate skill. This is the second failure shape the live queue hit:
    /// an unscoped pattern used to null the skill's confidence instead of its
    /// workstream and fail with "NOT NULL constraint failed: skills.confidence".
    func testUnscopedPatternStillProducesCandidateSkill() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let dayOne = Calendar.current.startOfDay(for: .now.addingTimeInterval(-2 * 86_400))
        try await fixture.record(CapturedEvent(
            timestamp: dayOne, kind: .session, applicationName: "macOS",
            bundleID: "com.apple.system", detail: "Screen sleep"
        ))
        let starts = [
            dayOne.addingTimeInterval(10 * 3_600),
            dayOne.addingTimeInterval(14 * 3_600),
            dayOne.addingTimeInterval(86_400 + 10 * 3_600),
        ]
        for start in starts {
            try await fixture.record(CapturedEvent(
                timestamp: start, kind: .terminal, applicationName: "Ghostty",
                bundleID: "com.mitchellh.ghostty", detail: "git status"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(30), kind: .terminal,
                applicationName: "Ghostty", bundleID: "com.mitchellh.ghostty", detail: "swift test"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(60), kind: .session,
                applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
            ))
        }

        // Evidence compaction runs off the capture path, so wait for all three
        // runs to carry the two actions a workflow trace needs.
        var readyTaskCount = 0
        for _ in 0..<100 {
            var ready = 0
            for task in try await fixture.context.recentTasks(limit: 20) {
                let evidence = try await fixture.context.evidence(for: task.id)
                if evidence.count >= 2 { ready += 1 }
            }
            readyTaskCount = ready
            if ready >= 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(readyTaskCount, 3, "The fixture must finish compacting evidence.")

        try await fixture.personal.prepare()
        try await fixture.personal.minePatterns(now: .now)

        let minedPatterns = try await fixture.personal.patterns(limit: 20)
        let pattern = try XCTUnwrap(minedPatterns.first)
        XCTAssertNil(pattern.scopeWorkstreamID, "This fixture must exercise the unscoped pattern path.")
        XCTAssertEqual(pattern.occurrenceCount, 3)

        // A pattern is signal, not a skill of its own: mining it must leave one
        // consolidated skill rather than one fragment per fingerprint.
        let candidates = try await fixture.personal.skills(status: .candidate, limit: 20)
        XCTAssertEqual(candidates.map(\.id), [WorkingStyleSynthesizer.skillID])
        await fixture.shutdown()
    }

    /// Form encoders write spaces as `+`, so an undecoded query arrives as one
    /// long token and silently matches no recall intent at all.
    func testFormEncodedQueryDecodesSpacesSoRecallIntentsStillMatch() throws {
        let items = LocalMemoryAPI.formDecodedQueryItems(
            "q=What+was+I+working+on+last%3F&limit=20&application=Google%20Chrome"
        )
        XCTAssertEqual(items["q"], "What was I working on last?")
        XCTAssertEqual(items["limit"], "20")
        XCTAssertEqual(items["application"], "Google Chrome")

        let resolved = RecallIntentResolver.resolve(MemoryQuery(text: items["q"], limit: 20))
        XCTAssertEqual(resolved.intent, .latest)
        XCTAssertEqual(resolved.query.limit, 1)

        XCTAssertTrue(LocalMemoryAPI.formDecodedQueryItems(nil).isEmpty)
        XCTAssertTrue(LocalMemoryAPI.formDecodedQueryItems("").isEmpty)
        XCTAssertEqual(LocalMemoryAPI.formDecodedQueryItems("pinned=true")["pinned"], "true")
        // A repeated key keeps the first value, as the previous parser did.
        XCTAssertEqual(LocalMemoryAPI.formDecodedQueryItems("q=one&q=two")["q"], "one")
    }

    /// "What was I working on last?" must skip the capture lifecycle episode
    /// that usually sits at the very end of a session and name real work.
    func testLatestRecallSkipsLifecycleNoiseAndReturnsRealWork() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let start = Date.now.addingTimeInterval(-600)
        try await fixture.record(CapturedEvent(
            timestamp: start, kind: .terminal, applicationName: "Ghostty",
            bundleID: "com.mitchellh.ghostty", windowTitle: "Mnemos", detail: "swift test"
        ))
        // The newest episode is lifecycle-only, exactly as it is on a real Mac.
        try await fixture.record(CapturedEvent(
            timestamp: start.addingTimeInterval(120), kind: .session,
            applicationName: "macOS", bundleID: "com.apple.system", detail: "System sleep"
        ))

        let resolved = RecallIntentResolver.resolve(MemoryQuery(text: "What was I working on last?"))
        XCTAssertEqual(resolved.intent, .latest)
        let results = try await fixture.context.search(resolved.query)
        let task = try XCTUnwrap(results.first?.task, "The latest question must still find real work.")
        XCTAssertTrue(task.applications.contains("Ghostty"))
        XCTAssertFalse(task.title.localizedCaseInsensitiveContains("macOS"))

        try await fixture.personal.prepare()
        let pack = try await fixture.personal.composeContext(query: "What was I working on last?", results: results)
        XCTAssertEqual(pack.memories.count, 1)
        XCTAssertNil(pack.coverageNote)
        await fixture.shutdown()
    }

    func testWorkingStyleSkillNamesRealToolsProjectsAndOrder() throws {
        var input = WorkingStyleSynthesizer.Input()
        input.apps = [
            .init(name: "ChatGPT", bundleID: "com.openai.chat", observations: 230),
            .init(name: "Ghostty", bundleID: "com.mitchellh.ghostty", observations: 214),
            .init(name: "Cursor", bundleID: "com.todesktop.cursor", observations: 160),
            .init(name: "Google Chrome", bundleID: "com.google.Chrome", observations: 138),
        ]
        input.projects = [
            .init(name: "mnemos", kind: .gitRepository, episodes: 6, lastActiveAt: .now),
            .init(name: "witlofe", kind: .localProject, episodes: 3, lastActiveAt: .now),
        ]
        input.transitions = [
            .init(from: "ChatGPT", to: "Cursor", count: 20),
            .init(from: "Cursor", to: "Ghostty", count: 18),
            .init(from: "Ghostty", to: "Google Chrome", count: 9),
            .init(from: "Cursor", to: "ChatGPT", count: 4),
        ]
        input.artifactRoots = ["/Users/sam/Desktop/witlofe"]
        input.episodeCount = 30
        input.dayCount = 4
        input.startHours = [9, 10, 10, 11, 11, 12, 14, 15, 16, 17]
        input.evidenceMemoryIDs = ["episode:a", "episode:b"]

        let draft = try XCTUnwrap(WorkingStyleSynthesizer.synthesize(input))
        let workflow = draft.workflow.joined(separator: "\n")
        // The order must follow the busiest observed handoffs, not app volume.
        XCTAssertTrue(workflow.contains("1. Work through the problem in ChatGPT"))
        XCTAssertTrue(workflow.contains("2. Edit code in Cursor"))
        XCTAssertTrue(workflow.contains("3. Run commands in Ghostty"))
        XCTAssertTrue(workflow.contains("mnemos"), "Real projects belong in the workflow.")

        XCTAssertTrue(draft.preferences.contains("Editor: Cursor"))
        XCTAssertTrue(draft.preferences.contains("Terminal: Ghostty"))
        XCTAssertTrue(draft.preferences.contains("Browser: Google Chrome"))
        XCTAssertTrue(draft.preferences.contains("AI assistant: ChatGPT"))

        // Nothing may read like the old raw event-kind fragments.
        for line in draft.workflow + draft.preferences {
            XCTAssertFalse(line.contains("_"), "Raw action tokens must not reach the skill: \(line)")
        }
        XCTAssertTrue(draft.constraints.contains { $0.contains("Git repositories in active use: mnemos") })
        XCTAssertEqual(draft.evidenceMemoryIDs, ["episode:a", "episode:b"])
    }

    /// The first live run produced "most active project is Web activity",
    /// "WhatsApp (also ‎WhatsApp)", "12:00 AM–11:00 PM", and a step for System
    /// Settings. None of that describes how somebody works.
    func testWorkingStyleSkillDropsNoiseThatMadeEarlierOutputUseless() throws {
        var input = WorkingStyleSynthesizer.Input()
        input.apps = [
            .init(name: "Cursor", observations: 160),
            .init(name: "System Settings", observations: 300),
            .init(name: "Finder", observations: 120),
            .init(name: "WhatsApp", observations: 28),
            // The same app, carrying an invisible left-to-right mark.
            .init(name: "\u{200E}WhatsApp", observations: 24),
            .init(name: "Ghostty", observations: 90),
        ]
        input.projects = [
            .init(name: "Web activity", kind: .website, episodes: 40, lastActiveAt: .now),
            .init(name: "mnemos", kind: .gitRepository, episodes: 6, lastActiveAt: .now),
        ]
        input.webSurfaces = ["github.com"]
        input.artifactRoots = ["/Users/sam/Desktop"]
        input.episodeCount = 30
        input.dayCount = 4
        // A single midnight session must not stretch the day to "12 AM–11 PM".
        input.startHours = [0, 9, 10, 10, 11, 11, 12, 13, 14, 23]

        let draft = try XCTUnwrap(WorkingStyleSynthesizer.synthesize(input))
        let everything = (draft.workflow + draft.preferences + draft.constraints + [draft.description])
            .joined(separator: "\n")
        XCTAssertFalse(everything.contains("System Settings"), "A utility surface is not a work step.")
        XCTAssertFalse(everything.contains("Finder"))
        XCTAssertFalse(everything.contains("Web activity"), "A website bucket is not a project.")
        XCTAssertFalse(everything.contains("also"), "Duplicate app names must merge: \(everything)")
        XCTAssertTrue(draft.preferences.contains("Communication: WhatsApp"))
        XCTAssertTrue(everything.contains("mnemos"))
        XCTAssertTrue(
            draft.constraints.contains { $0.contains("Frequently used web surfaces: github.com") },
            "Web hosts belong beside projects, not inside the project path list."
        )
        XCTAssertTrue(draft.constraints.contains { $0.contains("Project files live under /Users/sam/Desktop") })
        // 10th–90th percentile of the hours above is 9–14, not 0–23.
        XCTAssertTrue(
            draft.constraints.contains { $0.contains("Most work starts between") && !$0.contains("11:00 PM") },
            "Outlier hours must not define the working day: \(draft.constraints)"
        )
    }

    func testTypicalHoursStayQuietWhenTheSpreadSaysNothing() {
        XCTAssertNil(WorkingStyleSynthesizer.typicalHours([9, 10]), "Too few samples to claim a rhythm.")
        XCTAssertNil(
            WorkingStyleSynthesizer.typicalHours([0, 1, 6, 11, 14, 17, 20, 22, 23, 23]),
            "Round-the-clock activity has no typical window."
        )
        XCTAssertEqual(WorkingStyleSynthesizer.typicalHours([9, 10, 10, 11, 11, 12, 13, 14]), 9...14)
        // When no window holds, the busiest hours still carry real signal.
        XCTAssertEqual(
            WorkingStyleSynthesizer.busiestHours([0, 11, 11, 11, 13, 13, 13, 15, 15, 15, 23]),
            [11, 13, 15]
        )
        // The 10th and 90th percentile trim the two late outliers away.
        XCTAssertEqual(
            WorkingStyleSynthesizer.typicalHours([2, 9, 10, 10, 11, 11, 12, 13, 14, 23]), 9...14
        )
    }

    func testWorkingStyleSkillStaysSilentWithoutEnoughEvidence() throws {
        var input = WorkingStyleSynthesizer.Input()
        input.apps = [.init(name: "Cursor", observations: 4)]
        input.episodeCount = 2
        XCTAssertNil(
            WorkingStyleSynthesizer.synthesize(input),
            "Two episodes cannot support a claim about how someone works."
        )
    }

    func testWorkingStyleSkillDoesNotInventAVerificationHabit() throws {
        var input = WorkingStyleSynthesizer.Input()
        input.apps = [.init(name: "Cursor", observations: 40), .init(name: "Ghostty", observations: 30)]
        input.episodeCount = 10
        input.dayCount = 3
        let unverified = try XCTUnwrap(WorkingStyleSynthesizer.synthesize(input))
        XCTAssertTrue(unverified.verification.joined().contains("No verification step has been observed"))

        input.verificationCommands = ["swift test", "xcodebuild test"]
        let verified = try XCTUnwrap(WorkingStyleSynthesizer.synthesize(input))
        XCTAssertEqual(verified.verification, ["Observed check: swift test", "Observed check: xcodebuild test"])
        XCTAssertNotEqual(unverified.contentSignature, verified.contentSignature)
    }

    /// A two-way flip between two applications must not walk forever.
    func testDominantChainNeverRevisitsAnApplication() {
        let chain = WorkingStyleSynthesizer.dominantChain(
            transitions: [
                .init(from: "Cursor", to: "Ghostty", count: 50),
                .init(from: "Ghostty", to: "Cursor", count: 48),
            ],
            ranked: [.init(name: "Cursor", observations: 90), .init(name: "Ghostty", observations: 80)]
        )
        XCTAssertEqual(chain, ["Cursor", "Ghostty"])
    }

    func testWorkingStyleSkillVersionsOnlyWhenContentChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let dayOne = Calendar.current.startOfDay(for: .now.addingTimeInterval(-2 * 86_400))
        try await fixture.record(CapturedEvent(
            timestamp: dayOne, kind: .session, applicationName: "macOS",
            bundleID: "com.apple.system", detail: "Screen sleep"
        ))
        for index in 0..<4 {
            let start = dayOne.addingTimeInterval(Double(index) * 86_400 / 2 + 10 * 3_600)
            try await fixture.record(CapturedEvent(
                timestamp: start, kind: .keyboard, applicationName: "Cursor",
                bundleID: "com.todesktop.cursor", windowTitle: "mnemos", detail: "Edited the store"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(30), kind: .terminal, applicationName: "Ghostty",
                bundleID: "com.mitchellh.ghostty", detail: "swift test"
            ))
            try await fixture.record(CapturedEvent(
                timestamp: start.addingTimeInterval(60), kind: .session,
                applicationName: "macOS", bundleID: "com.apple.system", detail: "Capture session paused"
            ))
        }
        try await fixture.personal.prepare()

        let synthesized = try await fixture.personal.synthesizeWorkingStyleSkill()
        let first = try XCTUnwrap(synthesized)
        XCTAssertEqual(first.id, WorkingStyleSynthesizer.skillID)
        let firstPair = try await fixture.personal.skill(id: first.id)
        let firstVersion = try XCTUnwrap(firstPair).1
        XCTAssertEqual(firstVersion.version, 1)
        XCTAssertFalse(firstVersion.workflow.isEmpty)
        XCTAssertTrue(firstVersion.preferences.contains { $0.hasPrefix("Editor:") })

        // Re-running over unchanged activity must not churn out a new version.
        try await fixture.personal.synthesizeWorkingStyleSkill()
        let repeatedPair = try await fixture.personal.skill(id: first.id)
        let repeated = try XCTUnwrap(repeatedPair).1
        XCTAssertEqual(repeated.id, firstVersion.id)
        XCTAssertEqual(repeated.version, 1)
        await fixture.shutdown()
    }

    func testSchedulerUsesSixHourBoundariesAndDailyThreeAM() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 7, minute: 10))!
        let extraction = PersonalContextStore.nextExtraction(after: date, calendar: calendar)
        let consolidation = PersonalContextStore.nextConsolidation(after: date, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: extraction), 12)
        XCTAssertEqual(calendar.component(.hour, from: consolidation), 3)
        XCTAssertEqual(calendar.component(.day, from: consolidation), 30)
    }

    func testApprovedSkillExportsAsNonExecutableValidatedProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemos-skill-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let skill = PersonalSkill(
            id: "skill-1", currentVersionID: "version-1", title: "Test After Editing",
            description: "Run focused tests after editing project code.", scopeWorkstreamID: nil,
            status: .approved, confidence: 0.9, occurrenceCount: 7, updatedAt: now
        )
        let version = SkillVersion(
            id: "version-1", skillID: skill.id, version: 1, trigger: "When project code changes",
            workflow: ["Edit text", "Run tests", "Review changes"], preferences: [], constraints: [],
            verification: ["Confirm the focused test passes"], evidenceMemoryIDs: ["memory-1"],
            approvedAt: now, createdAt: now
        )
        let exported = try NativeSkillExporter.export(skill: skill, version: version, root: root)
        let markdown = try String(contentsOf: exported.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("name: mnemos-test-after-editing"))
        XCTAssertTrue(markdown.contains("Run tests"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("scripts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("mnemos-manifest.json").path))
    }

    /// The plan's hardest gate: nothing an agent can reach may return a skill
    /// the user has not approved.
    func testAgentSurfacesNeverReturnUnapprovedSkills() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()
        try await fixture.personal.seedSkillForTesting(
            id: "skill-candidate", title: "Run Tests After Editing",
            description: "Run focused tests after editing project code.", status: .candidate,
            versions: [(id: "v1", number: 1, trigger: "when project code changes", workflow: ["edit", "test"], approvedAt: nil)]
        )

        let visibleToAgents = try await fixture.personal.skills(status: .approved, limit: 50)
        XCTAssertTrue(visibleToAgents.isEmpty, "A candidate skill must never reach an agent surface.")
        let relevant = try await fixture.personal.relevantSkills(
            query: "project code changes", workstreamID: nil, applications: []
        )
        XCTAssertTrue(relevant.isEmpty)

        try await fixture.personal.approveSkill(id: "skill-candidate")
        let afterApproval = try await fixture.personal.skills(status: .approved, limit: 50)
        XCTAssertEqual(afterApproval.count, 1)
        await fixture.shutdown()
    }

    func testRetiredSkillLeavesEveryAgentSurface() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()
        try await fixture.personal.seedSkillForTesting(
            id: "skill-retire", title: "Review Before Commit",
            description: "Review the diff before committing.", status: .candidate,
            versions: [(id: "v1", number: 1, trigger: "before commit", workflow: ["review", "commit"], approvedAt: nil)]
        )
        try await fixture.personal.approveSkill(id: "skill-retire")
        let approvedSkills = try await fixture.personal.skills(status: .approved, limit: 50)
        XCTAssertEqual(approvedSkills.count, 1)

        try await fixture.personal.retireSkill(id: "skill-retire")
        let afterRetire = try await fixture.personal.skills(status: .approved, limit: 50)
        XCTAssertTrue(afterRetire.isEmpty)
        let relevantAfterRetire = try await fixture.personal.relevantSkills(
            query: "before commit", workstreamID: nil, applications: []
        )
        XCTAssertTrue(relevantAfterRetire.isEmpty)
        await fixture.shutdown()
    }

    /// The packet is the only thing that ever leaves this Mac, and the
    /// Intelligence tab now shows it verbatim. It must contain nothing from a
    /// source the user did not consent to, and no redacted secret.
    func testOutboundPacketExcludesNonConsentedSourcesAndSecrets() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        UserDefaults.standard.set(true, forKey: PersonalContextStore.cloudEnabledDefaultsKey)
        await fixture.personal.setCloudSources(bundleIDs: ["com.mitchellh.ghostty"], domains: [])

        let start = Date.now.addingTimeInterval(-3_600)
        let events = [
            CapturedEvent(
                timestamp: start, kind: .terminal, applicationName: "Ghostty",
                bundleID: "com.mitchellh.ghostty", windowTitle: "deploy", detail: "swift test run"
            ),
            // Consented source carrying something redaction must remove.
            CapturedEvent(
                timestamp: start.addingTimeInterval(1), kind: .terminal, applicationName: "Ghostty",
                bundleID: "com.mitchellh.ghostty", windowTitle: "deploy",
                detail: "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"
            ),
            CapturedEvent(
                timestamp: start.addingTimeInterval(2), kind: .terminal, applicationName: "Ghostty",
                bundleID: "com.mitchellh.ghostty", windowTitle: "deploy", detail: "git commit -m ship"
            ),
            // A source the user never consented to send.
            CapturedEvent(
                timestamp: start.addingTimeInterval(5), kind: .terminal, applicationName: "Notes",
                bundleID: "com.apple.Notes", windowTitle: "Private journal",
                detail: "personal-journal-entry-marker"
            ),
            CapturedEvent(
                timestamp: start.addingTimeInterval(10), kind: .session, applicationName: "macOS",
                bundleID: "com.apple.system", detail: "Capture session paused"
            ),
        ]
        for event in events { try await fixture.record(event) }
        try await Task.sleep(for: .milliseconds(100))
        try await fixture.personal.prepare()

        let packet = try await fixture.personal.evidencePacket(
            from: start.addingTimeInterval(-60), to: Date.now
        )
        let rendered = String(data: try JSONEncoder().encode(packet), encoding: .utf8) ?? ""

        // Without this the negative assertions could pass on an empty packet.
        XCTAssertFalse(packet.tasks.isEmpty, "The consented source should produce a packet task.")
        XCTAssertTrue(rendered.contains("Ghostty"), "The consented application should be present.")

        XCTAssertFalse(
            rendered.contains("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"),
            "A redacted secret must never appear in an outbound packet."
        )
        XCTAssertFalse(
            rendered.contains("personal-journal-entry-marker"),
            "Evidence from a source the user did not consent to must never be sent."
        )
        XCTAssertFalse(
            rendered.contains("com.apple.Notes") || rendered.contains("Private journal"),
            "A non-consented application must not appear in an outbound packet at all."
        )
        await fixture.shutdown()
    }

    func testGrantTokensResolveOnlyWhileActive() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()

        let issued = try await fixture.personal.createGrant(
            displayName: "Claude Code", capabilities: [.memories, .skills]
        )
        XCTAssertFalse(issued.token.isEmpty)

        let resolved = try await fixture.personal.resolveGrant(token: issued.token)
        XCTAssertEqual(resolved?.id, issued.grant.id)
        XCTAssertTrue(resolved?.allows(.memories) == true)
        XCTAssertFalse(resolved?.allows(.evidence) == true, "Evidence is a separate permission.")

        // A wrong token never resolves.
        let bogus = try await fixture.personal.resolveGrant(token: "not-a-real-token")
        XCTAssertNil(bogus)

        // Revocation takes effect immediately.
        try await fixture.personal.revokeGrant(id: issued.grant.id)
        let afterRevoke = try await fixture.personal.resolveGrant(token: issued.token)
        XCTAssertNil(afterRevoke)

        try await fixture.personal.restoreGrant(id: issued.grant.id)
        let afterRestore = try await fixture.personal.resolveGrant(token: issued.token)
        XCTAssertEqual(afterRestore?.id, issued.grant.id)
        await fixture.shutdown()
    }

    /// The token itself is never persisted, only its hash.
    func testGrantTokensAreNotStoredInThePlainDatabase() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()
        let issued = try await fixture.personal.createGrant(
            displayName: "Cursor", capabilities: [.memories]
        )
        await fixture.shutdown()

        let raw = try Data(contentsOf: fixture.database)
        let hash = SHA256.hash(data: Data(issued.token.utf8))
            .map { String(format: "%02x", $0) }.joined()
        // Proves the row really reached this file, so the negative assertion
        // below cannot pass merely because nothing was flushed.
        XCTAssertNotNil(raw.range(of: Data(hash.utf8)), "The grant row should be persisted.")
        XCTAssertNil(
            raw.range(of: Data(issued.token.utf8)),
            "The plaintext grant token must never appear in the database file."
        )
    }

    /// Rotating the launch token must not silently widen a narrowed grant.
    func testDefaultGrantKeepsItsCapabilitiesAcrossTokenRotation() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()

        let first = try await fixture.personal.refreshDefaultGrant(token: "launch-token-one")
        XCTAssertTrue(first.isDefault)
        XCTAssertTrue(first.allows(.evidence), "The built-in grant starts with today's full access.")

        try await fixture.personal.setGrantCapabilities(
            id: PersonalContextStore.defaultGrantID, capabilities: [.memories]
        )
        let rotated = try await fixture.personal.refreshDefaultGrant(token: "launch-token-two")
        XCTAssertEqual(rotated.capabilities, [.memories])
        XCTAssertFalse(rotated.allows(.evidence))

        // The old token stops working once rotated.
        let stale = try await fixture.personal.resolveGrant(token: "launch-token-one")
        XCTAssertNil(stale)
        let current = try await fixture.personal.resolveGrant(token: "launch-token-two")
        XCTAssertEqual(current?.id, PersonalContextStore.defaultGrantID)

        // Rotation preserves the recorded last use rather than resetting it.
        let storedGrant = try await fixture.personal.grant(id: PersonalContextStore.defaultGrantID)
        let used = try XCTUnwrap(storedGrant?.lastUsedAt)
        let afterRotation = try await fixture.personal.refreshDefaultGrant(token: "launch-token-three")
        XCTAssertEqual(
            afterRotation.lastUsedAt?.timeIntervalSince1970 ?? 0,
            used.timeIntervalSince1970, accuracy: 0.001
        )
        await fixture.shutdown()
    }

    /// The composer's 20% action-prefix term: how far the steps taken so far
    /// run along the start of a skill's workflow.
    func testActionPrefixMatchScoresAlignmentNotOverlap() {
        let workflow = ["edit_text", "run_tests", "review_changes", "commit_changes"]

        // Nothing done yet, or an unrelated start, earns nothing.
        XCTAssertEqual(PersonalContextStore.actionPrefixMatch(observed: [], workflow: workflow), 0)
        XCTAssertEqual(
            PersonalContextStore.actionPrefixMatch(observed: ["visit_page"], workflow: workflow), 0
        )

        // Two aligned steps out of two observed is a complete prefix so far.
        XCTAssertEqual(
            PersonalContextStore.actionPrefixMatch(observed: ["edit_text", "run_tests"], workflow: workflow),
            1.0, accuracy: 0.0001
        )

        // Repeats collapse, so idling in one app neither helps nor hurts.
        XCTAssertEqual(
            PersonalContextStore.actionPrefixMatch(
                observed: ["edit_text", "edit_text", "edit_text", "run_tests"], workflow: workflow
            ),
            1.0, accuracy: 0.0001
        )

        // Divergence stops the match: the third step breaks the alignment, so
        // only the first two of three observed steps count.
        XCTAssertEqual(
            PersonalContextStore.actionPrefixMatch(
                observed: ["edit_text", "run_tests", "visit_page"], workflow: workflow
            ),
            2.0 / 3.0, accuracy: 0.0001
        )

        // A later-but-matching subsequence is not a prefix, and scores nothing.
        XCTAssertEqual(
            PersonalContextStore.actionPrefixMatch(
                observed: ["run_tests", "review_changes"], workflow: workflow
            ),
            0
        )
    }

    /// Retrieval is counted, but nothing about the agent's request is stored.
    func testSkillRetrievalIsRecordedWithoutRequestContent() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()
        try await fixture.personal.seedSkillForTesting(
            id: "skill-usage", title: "Verify Before Reporting Done",
            // Trigger and description share wording, and the action prefix
            // matches the workflow, so the threshold is cleared on the ranker's
            // own terms rather than by relaxing it for the test.
            description: "verify outcome before reporting done", status: .candidate,
            versions: [(id: "v1", number: 1, trigger: "verify outcome before reporting done", workflow: ["edit_text", "run_tests"], approvedAt: nil)]
        )
        try await fixture.personal.approveSkill(id: "skill-usage")

        let before = try await fixture.personal.skillActivity(skillID: "skill-usage")
        XCTAssertEqual(before.retrievalCount, 0)
        XCTAssertNil(before.lastRetrievedAt)

        let matched = try await fixture.personal.relevantSkills(
            query: "verify outcome before reporting done", workstreamID: nil,
            applications: [], actionPrefix: ["edit_text", "run_tests"]
        )
        XCTAssertFalse(matched.isEmpty, "The seeded trigger should match its own wording.")

        let after = try await fixture.personal.skillActivity(skillID: "skill-usage")
        XCTAssertEqual(after.retrievalCount, 1)
        XCTAssertNotNil(after.lastRetrievedAt)
        XCTAssertNil(after.exportedVersion, "Retrieval must not imply an export.")
        await fixture.shutdown()
    }

    func testRollbackOnlyRestoresAPreviouslyApprovedVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try await fixture.prepareStores()
        let approved = Date.now.addingTimeInterval(-3_600)
        try await fixture.personal.seedSkillForTesting(
            id: "skill-versions", title: "Stage Then Commit",
            description: "Stage related changes before committing.", status: .approved,
            versions: [
                (id: "v1", number: 1, trigger: "before commit", workflow: ["stage", "commit"], approvedAt: approved),
                (id: "v2", number: 2, trigger: "before commit", workflow: ["stage", "review", "commit"], approvedAt: nil),
            ]
        )
        let history = try await fixture.personal.skillVersions(skillID: "skill-versions")
        XCTAssertEqual(history.map(\.version), [2, 1], "History is newest first.")

        // v2 was never approved, so it is not a valid rollback target.
        var rejectedUnapprovedTarget = false
        do { try await fixture.personal.rollbackSkill(id: "skill-versions", toVersionID: "v2") }
        catch { rejectedUnapprovedTarget = true }
        XCTAssertTrue(rejectedUnapprovedTarget)

        try await fixture.personal.rollbackSkill(id: "skill-versions", toVersionID: "v1")
        let restored = try await fixture.personal.skill(id: "skill-versions")
        let pair = try XCTUnwrap(restored)
        XCTAssertEqual(pair.1.version, 1)
        XCTAssertEqual(pair.0.status, .approved)
        await fixture.shutdown()
    }

    func testExportCanBeRemovedAndOnlyTouchesMnemosPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemos-skill-uninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        let skill = PersonalSkill(
            id: "skill-1", currentVersionID: "version-1", title: "Test After Editing",
            description: "Run focused tests after editing project code.", scopeWorkstreamID: nil,
            status: .approved, confidence: 0.9, occurrenceCount: 7, updatedAt: now
        )
        let version = SkillVersion(
            id: "version-1", skillID: skill.id, version: 1, trigger: "When project code changes",
            workflow: ["Edit text", "Run tests"], preferences: [], constraints: [],
            verification: [], evidenceMemoryIDs: [], approvedAt: now, createdAt: now
        )
        let exported = try NativeSkillExporter.export(skill: skill, version: version, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        // The preview shown in the app is the same text that was written.
        let markdown = try String(contentsOf: exported.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertEqual(markdown, NativeSkillExporter.agentFacingMarkdown(skill: skill, version: version))

        XCTAssertTrue(try NativeSkillExporter.removeExport(skill: skill, root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertFalse(try NativeSkillExporter.removeExport(skill: skill, root: root))

        // A folder Mnemos did not write has no manifest and is left alone.
        let foreign = root.appendingPathComponent("mnemos-test-after-editing", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("SKILL.md"))
        XCTAssertFalse(try NativeSkillExporter.removeExport(skill: skill, root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    private func restore(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

private extension PersonalContextTests {
    final class Fixture: @unchecked Sendable {
        let directory: URL
        let database: URL
        let legacy: SQLiteMemoryStore
        let context: ContextEngineStore
        let personal: PersonalContextStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mnemos-v3-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = directory.appendingPathComponent("fixture.sqlite")
            legacy = SQLiteMemoryStore(databaseURL: database)
            context = ContextEngineStore(databaseURL: database)
            personal = PersonalContextStore(databaseURL: database)
        }

        /// V3 layers on top of the V1 and V2 schemas. One lifecycle-only event
        /// runs those migrations without creating a memory of its own.
        func prepareStores() async throws {
            try await record(CapturedEvent(
                timestamp: .now, kind: .session, applicationName: "macOS",
                bundleID: "com.apple.system", detail: "Screen sleep"
            ))
            try await personal.prepare()
        }

        func record(_ event: CapturedEvent) async throws {
            try await legacy.record(event)
            try await context.record(event)
        }

        func shutdown() async {
            await personal.shutdownForTesting()
            await context.shutdownForTesting()
            await legacy.shutdownForTesting()
        }

        func removeFiles() { try? FileManager.default.removeItem(at: directory) }

        func executeSQL(_ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
                throw NSError(domain: "PersonalContextTests", code: 1)
            }
            defer { sqlite3_close(handle) }
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? "SQLite fixture update failed."
                sqlite3_free(message)
                throw NSError(domain: "PersonalContextTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: detail,
                ])
            }
        }
    }
}
