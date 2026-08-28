import Foundation
import XCTest
@testable import Mnemos

final class NarrativeTests: XCTestCase {
    // MARK: - Fixtures

    private func task(
        title: String = "Activity in Ghostty",
        actions: [String] = ["typed"],
        applications: [String] = ["Ghostty"],
        artifacts: [String] = [],
        lastState: String? = nil,
        workstream: Workstream? = nil,
        isUserLocked: Bool = false,
        isOpen: Bool = false,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date = Date(timeIntervalSince1970: 1_700_002_760)
    ) -> TaskMemory {
        TaskMemory(
            id: "task", sessionID: "session", workstream: workstream,
            startedAt: startedAt, endedAt: endedAt, title: title,
            digest: "Worked using Ghostty. Actions: typed.", actions: actions,
            applications: applications, artifacts: artifacts, lastState: lastState,
            eventCount: 47, isPinned: false, groupingConfidence: 0.9,
            groupingReasons: ["same_workstream"], isOpen: isOpen, isUserLocked: isUserLocked
        )
    }

    private func project(_ name: String) -> Workstream {
        Workstream(
            id: "ws", kind: .gitRepository, canonicalKey: "git:\(name)",
            displayName: name, userConfirmed: false
        )
    }

    private func span(
        applicationName: String = "Xcode",
        windowTitle: String? = nil,
        documentPath: String? = nil,
        url: String? = nil,
        anchorKey: String? = nil
    ) -> ActivitySpan {
        ActivitySpan(
            id: "span", taskID: "task",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            applicationName: applicationName, bundleID: "com.example.app",
            windowTitle: windowTitle, documentPath: documentPath, url: url,
            anchorKey: anchorKey, eventCount: 12
        )
    }

    // MARK: - Titles

    func testActivityInAppBecomesASentence() {
        XCTAssertEqual(Narrative.title(for: task(title: "Activity in Ghostty")), "Worked in Ghostty")
    }

    func testApplicationSuffixIsStripped() {
        let value = task(title: "AppModel.swift — Xcode", applications: ["Xcode"])
        XCTAssertEqual(Narrative.title(for: value), "AppModel.swift")
    }

    func testUnrelatedSuffixIsKept() {
        let value = task(title: "Fix the race — take two", applications: ["Xcode"])
        XCTAssertEqual(Narrative.title(for: value), "Fix the race — take two")
    }

    func testPathTitleShowsFileName() {
        let value = task(title: "/Users/sam/projects/mnemos/AppModel.swift", applications: ["Xcode"])
        XCTAssertEqual(Narrative.title(for: value), "AppModel.swift")
    }

    func testUserRenamedTitleIsUntouched() {
        let value = task(title: "Activity in Ghostty", isUserLocked: true)
        XCTAssertEqual(Narrative.title(for: value), "Activity in Ghostty")
    }

    func testLongTitleIsTruncatedOnAWordBoundary() {
        let long = String(repeating: "recovering memory persistence ", count: 6)
        let result = Narrative.title(for: task(title: long))
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThanOrEqual(result.count, 71)
        XCTAssertFalse(result.contains("  "))
    }

    // MARK: - Summaries

    func testSummaryReadsAsPlainEnglish() {
        let value = task(
            actions: ["typed", "used terminal"],
            applications: ["Codex", "Xcode"],
            lastState: "/Users/sam/projects/mnemos/AppModel.swift",
            workstream: project("computer-history")
        )
        XCTAssertEqual(
            Narrative.summary(for: value),
            "Ran commands in Codex and Xcode on computer-history. Last on AppModel.swift."
        )
    }

    func testSummaryNeverLeaksEngineVocabulary() {
        let value = task(actions: ["navigated"], applications: ["Safari", "Notes", "Mail", "Slack"])
        let summary = Narrative.summary(for: value)
        for jargon in ["Actions:", "digest", "event", "workstream", "span", "evidence"] {
            XCTAssertFalse(summary.lowercased().contains(jargon.lowercased()), "leaked \(jargon)")
        }
    }

    func testSummaryWithoutAppsOrLastState() {
        let value = task(actions: [], applications: [], workstream: project("computer-history"))
        XCTAssertEqual(Narrative.summary(for: value), "Worked on computer-history.")
    }

    func testSummaryWithNothingAtAll() {
        XCTAssertEqual(Narrative.summary(for: task(actions: [], applications: [])), "Worked.")
    }

    // MARK: - Places and steps

    func testLastPlaceShortensLinks() {
        let value = task(lastState: "https://www.github.com/samar-58/mnemos/pull/12")
        XCTAssertEqual(Narrative.lastPlace(for: value), "github.com/samar-58/mnemos")
    }

    func testLastPlaceIsNilWhenBlank() {
        XCTAssertNil(Narrative.lastPlace(for: task(lastState: "   ")))
        XCTAssertNil(Narrative.lastPlace(for: task(lastState: nil)))
    }

    func testStepPrefersFilesThenLinksThenWindowTitle() {
        XCTAssertEqual(
            Narrative.step(for: span(documentPath: "/Users/sam/AppModel.swift")),
            "Worked in Xcode on AppModel.swift"
        )
        XCTAssertEqual(
            Narrative.step(for: span(url: "https://github.com/samar-58/mnemos")),
            "Read github.com/samar-58/mnemos"
        )
        XCTAssertEqual(
            Narrative.step(for: span(windowTitle: "ContextEngineStore.swift — Xcode")),
            "Worked in Xcode on ContextEngineStore.swift"
        )
        XCTAssertEqual(Narrative.step(for: span()), "Worked in Xcode")
    }

    func testArtifactLabelKeepsTheFullValueForHover() {
        let item = Narrative.artifact("/Users/sam/projects/mnemos/AppModel.swift")
        XCTAssertEqual(item.label, "AppModel.swift")
        XCTAssertEqual(item.detail, "/Users/sam/projects/mnemos/AppModel.swift")
    }

    // MARK: - Meta

    func testMetaShowsTimeProjectAndAppsAndNoCounts() {
        let value = task(applications: ["Codex", "Xcode"], workstream: project("computer-history"))
        let meta = Narrative.meta(for: value)
        XCTAssertTrue(meta.contains("computer-history"))
        XCTAssertTrue(meta.contains("Codex + Xcode"))
        XCTAssertFalse(meta.contains("47"))
    }

    func testOpenTaskReportsRunningTime() {
        let value = task(isOpen: true, startedAt: Date().addingTimeInterval(-600), endedAt: Date())
        XCTAssertTrue(Narrative.timeRange(for: value).contains("since"))
    }

    // MARK: - Clipboard

    func testClipboardTextIsUnchangedByTheRewrite() {
        let value = task(
            title: "Activity in Ghostty",
            artifacts: ["/Users/sam/AppModel.swift"],
            lastState: "/Users/sam/AppModel.swift"
        )
        let text = ContextClipboard.text(task: value, evidence: [])
        // The agent-facing format keeps the stored title and digest verbatim.
        XCTAssertTrue(text.hasPrefix("# Activity in Ghostty"))
        XCTAssertTrue(text.contains("Worked using Ghostty. Actions: typed."))
        XCTAssertTrue(text.contains("Left off at: /Users/sam/AppModel.swift"))
        XCTAssertTrue(text.contains("- /Users/sam/AppModel.swift"))
    }
}
