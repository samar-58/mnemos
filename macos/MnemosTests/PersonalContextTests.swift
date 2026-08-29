import CryptoKit
import Foundation
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
    }
}
