import Foundation
import XCTest
@testable import Mnemos

/// Covers the presentation rules the timeline depends on: which derived project
/// names are fit to show, which recorded states answer "where did I leave off",
/// how a day's episodes roll up, and how repeated activity collapses.
final class TimelinePresentationTests: XCTestCase {
    // MARK: - Fixtures

    private func task(
        id: String = "task",
        title: String = "Activity in Ghostty",
        workstream: Workstream? = nil,
        isUserLocked: Bool = false,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: TimeInterval = 600,
        applications: [String] = ["Ghostty"],
        artifacts: [String] = [],
        lastState: String? = nil
    ) -> TaskMemory {
        TaskMemory(
            id: id, sessionID: "session", workstream: workstream,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(durationSeconds),
            title: title, digest: "Worked using Ghostty.", actions: ["typed"],
            applications: applications, artifacts: artifacts, lastState: lastState,
            eventCount: 10, isPinned: false, groupingConfidence: 0.9,
            groupingReasons: [], isOpen: false, isUserLocked: isUserLocked
        )
    }

    private func project(_ id: String, _ name: String) -> Workstream {
        Workstream(
            id: id, kind: .gitRepository, canonicalKey: "git:\(name)",
            displayName: name, userConfirmed: false
        )
    }

    private func span(
        id: String,
        applicationName: String = "Ghostty",
        windowTitle: String? = nil,
        documentPath: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: TimeInterval = 60
    ) -> ActivitySpan {
        ActivitySpan(
            id: id, taskID: "task", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationSeconds),
            applicationName: applicationName, bundleID: "com.example.app",
            windowTitle: windowTitle, documentPath: documentPath, url: nil,
            anchorKey: nil, eventCount: 5
        )
    }

    // MARK: - Project names

    func testDerivedURLFragmentsAreNotOfferedAsProjects() {
        for fragment in ["https:", "65", "www", "/", "about"] {
            XCTAssertFalse(
                ProjectName.isMeaningful(fragment),
                "\(fragment) should not earn a sidebar row"
            )
        }
    }

    /// A name that only looks broken because of its query string is kept — it
    /// is cleaned up rather than hidden.
    func testNamesWithQueryStringsAreCleanedRatherThanDropped() {
        XCTAssertTrue(ProjectName.isMeaningful("partner?expand=1"))
        XCTAssertEqual(ProjectName.display("partner?expand=1"), "partner")
    }

    func testOpaqueIdentifiersAreNotOfferedAsProjects() {
        XCTAssertFalse(ProjectName.isMeaningful("AAQkADVhNzg3ZmQ2LTk4NGYt"))
    }

    func testRealProjectNamesSurvive() {
        for name in ["mnemos", "logistics-mobile-app-porter-v1", "computer-history", "Del-ex-website"] {
            XCTAssertTrue(ProjectName.isMeaningful(name), "\(name) should be shown")
        }
    }

    func testDisplayNameDropsQueryStrings() {
        XCTAssertEqual(ProjectName.display("partner-flow?expand=1"), "partner-flow")
        XCTAssertEqual(ProjectName.display("/logistics-api-server/"), "logistics-api-server")
    }

    // MARK: - Last state

    func testKeystrokesAreNotAnAnswerToWhereYouLeftOff() {
        for state in ["⌘W", "⌘⇧K", "⌥", "-", "42"] {
            XCTAssertFalse(LastState.isMeaningful(state), "\(state) should be suppressed")
        }
    }

    func testRealLocationsSurviveAsLastState() {
        XCTAssertTrue(LastState.isMeaningful("hybrid-pickup.ts"))
        XCTAssertTrue(LastState.isMeaningful("github.com/samar-58/mnemos"))
    }

    func testTaskWithKeystrokeStateHasNoLastPlace() {
        XCTAssertNil(Narrative.lastPlace(for: task(lastState: "⌘W")))
    }

    // MARK: - Roll-up

    func testEpisodesOfOneProjectCollapseIntoASingleEntry() {
        let repository = project("ws1", "logistics-mobile-app-porter-v1")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tasks = (0..<6).map { index in
            task(
                id: "t\(index)",
                title: "Working on logistics-mobile-app-porter-v1",
                workstream: repository,
                startedAt: base.addingTimeInterval(Double(index) * -3_600)
            )
        }

        let groups = TimelineGroup.group(tasks)

        XCTAssertEqual(groups.count, 1, "six episodes of one project are one line")
        XCTAssertTrue(groups[0].isGroup)
        XCTAssertEqual(groups[0].tasks.count, 6)
        XCTAssertEqual(groups[0].taskIDs.count, 6)
    }

    func testSeparateProjectsStayApart() {
        let tasks = [
            task(id: "a", workstream: project("ws1", "mnemos")),
            task(id: "b", workstream: project("ws2", "witlofe")),
            task(id: "c", workstream: project("ws1", "mnemos")),
        ]

        let groups = TimelineGroup.group(tasks)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].tasks.map(\.id), ["a", "c"], "order follows first appearance")
        XCTAssertEqual(groups[1].tasks.map(\.id), ["b"])
        XCTAssertFalse(groups[1].isGroup, "a lone episode is a plain row")
    }

    func testProjectlessEpisodesGroupByTitle() {
        let tasks = [
            task(id: "a", title: "Activity in Ghostty"),
            task(id: "b", title: "Activity in Ghostty"),
            task(id: "c", title: "Activity in Safari", applications: ["Safari"]),
        ]

        let groups = TimelineGroup.group(tasks)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].tasks.count, 2)
    }

    func testARenamedEpisodeIsNeverFoldedAway() {
        let repository = project("ws1", "mnemos")
        let tasks = [
            task(id: "a", workstream: repository),
            task(id: "b", title: "Fixing the migration bug", workstream: repository, isUserLocked: true),
            task(id: "c", workstream: repository),
        ]

        let groups = TimelineGroup.group(tasks)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { !$0.isGroup }?.tasks.map(\.id), ["b"])
    }

    func testGroupTimeIsSummedNotMeasuredEndToEnd() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = project("ws1", "mnemos")
        // Two ten-minute episodes three hours apart: the gap is not work.
        let tasks = [
            task(id: "a", workstream: repository, startedAt: base, durationSeconds: 600),
            task(id: "b", workstream: repository, startedAt: base.addingTimeInterval(10_800), durationSeconds: 600),
        ]

        let group = TimelineGroup.group(tasks)[0]

        XCTAssertEqual(group.activeSeconds, 1_200)
        XCTAssertEqual(group.endedAt.timeIntervalSince(group.startedAt), 11_400)
    }

    // MARK: - Activity collapse

    func testConsecutiveLookAlikeSpansBecomeOneStep() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spans = [
            span(id: "s1", windowTitle: "porter-v1", startedAt: base),
            span(id: "s2", windowTitle: "porter-v1", startedAt: base.addingTimeInterval(60)),
            span(id: "s3", windowTitle: "porter-v1", startedAt: base.addingTimeInterval(120)),
        ]

        let steps = ActivityStep.collapse(spans)

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].visitCount, 3)
        XCTAssertEqual(steps[0].spanIDs, ["s1", "s2", "s3"], "every span stays addressable for split and move")
        XCTAssertEqual(steps[0].activeSeconds, 180)
    }

    func testADifferentStepBreaksTheRun() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spans = [
            span(id: "s1", windowTitle: "porter-v1", startedAt: base),
            span(id: "s2", applicationName: "Cursor", windowTitle: "hybrid-pickup.ts", startedAt: base.addingTimeInterval(60)),
            span(id: "s3", windowTitle: "porter-v1", startedAt: base.addingTimeInterval(120)),
        ]

        let steps = ActivityStep.collapse(spans)

        XCTAssertEqual(steps.count, 3, "returning to something is a separate visit, not the same run")
        XCTAssertEqual(steps.map(\.visitCount), [1, 1, 1])
    }

    func testCollapsingNothingProducesNothing() {
        XCTAssertTrue(ActivityStep.collapse([]).isEmpty)
    }

    // MARK: - Artifacts

    func testArtifactListDropsDuplicatesAndTheProjectItself() {
        let repository = project("ws1", "logistics-mobile-app-porter-v1")
        let subject = task(
            workstream: repository,
            artifacts: [
                "/Users/me/code/logistics-mobile-app-porter-v1",
                "/Users/me/code/logistics-mobile-app-porter-v1/src/hybrid-pickup.ts",
                "/Users/me/other/hybrid-pickup.ts",
            ]
        )

        let items = Narrative.artifacts(for: subject)

        XCTAssertEqual(items.map(\.label), ["hybrid-pickup.ts"])
    }
}
