import Foundation

enum WorkstreamKind: String, Codable, CaseIterable, Sendable {
    case gitRepository = "git_repository"
    case localProject = "local_project"
    case website
    case conversation
    case custom
}

struct Workstream: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: WorkstreamKind
    let canonicalKey: String
    let displayName: String
    let userConfirmed: Bool
}

/// A workstream with the counts the sidebar needs, so the UI does not have to
/// load every task to label a row.
struct WorkstreamSummary: Identifiable, Equatable, Codable, Sendable {
    let workstream: Workstream
    let taskCount: Int
    let lastActivityAt: Date?

    var id: String { workstream.id }
}

struct WorkSession: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let taskCount: Int
    let applications: [String]
    let isOpen: Bool
}

struct RecentActivity: Equatable, Codable, Sendable {
    let sessions: [WorkSession]
    let tasks: [TaskMemory]
}

struct TaskMemory: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let sessionID: String
    let workstream: Workstream?
    let startedAt: Date
    let endedAt: Date
    let title: String
    let digest: String
    let actions: [String]
    let applications: [String]
    let artifacts: [String]
    let lastState: String?
    let eventCount: Int
    let isPinned: Bool
    let groupingConfidence: Double
    let groupingReasons: [String]
    let isOpen: Bool
    let isUserLocked: Bool
}

struct ActivitySpan: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let taskID: String
    let startedAt: Date
    let endedAt: Date
    let applicationName: String
    let bundleID: String
    let windowTitle: String?
    let documentPath: String?
    let url: String?
    let anchorKey: String?
    let eventCount: Int
}

enum EvidenceSource: String, Codable, Sendable {
    case raw
    case compacted
    case userSelected = "user_selected"
}

struct EvidenceItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let taskID: String
    let observationID: String?
    let timestamp: Date
    let kind: String
    let applicationName: String
    let excerpt: String?
    let url: String?
    let documentPath: String?
    let target: String?
    let source: EvidenceSource
    let priority: Int
    let redactionPolicyVersion: Int
}

struct ContextSearchResult: Identifiable, Equatable, Codable, Sendable {
    let task: TaskMemory
    let score: Double
    let highlights: [String]
    let matchReasons: [String]
    let evidencePreviews: [EvidenceItem]

    var id: String { task.id }
}

struct TaskContext: Equatable, Codable, Sendable {
    let task: TaskMemory
    let spans: [ActivitySpan]
    let evidence: [EvidenceItem]
    let previousTask: TaskMemory?
    let nextTask: TaskMemory?
}

struct ContextPack: Equatable, Codable, Sendable {
    let query: String?
    let results: [ContextSearchResult]
    let generatedAt: Date
}

struct EvidencePage: Equatable, Codable, Sendable {
    let data: [EvidenceItem]
    let nextCursor: String?
}

struct TimelineEntry: Identifiable, Equatable, Codable, Sendable {
    let task: TaskMemory
    let session: WorkSession

    var id: String { task.id }
}

struct MemoryQuery: Equatable, Sendable {
    var text: String?
    var from: Date?
    var to: Date?
    var application: String?
    var workstream: String?
    var pinnedOnly = false
    var limit = 10
    var sortOrder: MemorySortOrder = .relevance
    var anchorAfterWake = false
    /// Drops capture lifecycle episodes — sleep, wake, session pauses — that
    /// carry no evidence and never become a memory, so a recall question is
    /// answered with real work instead of system noise.
    var meaningfulOnly = false
}

enum MemorySortOrder: Equatable, Sendable {
    case relevance
    case recent
    case chronological
}

enum RecallIntent: Equatable, Sendable {
    case latest
    case lastNight
    case firstMorningActivity
    case calendarDay(Date)
}

enum RecallIntentResolver {
    static func resolve(
        _ query: MemoryQuery, now: Date = .now, calendar: Calendar = .current
    ) -> (query: MemoryQuery, intent: RecallIntent?) {
        guard query.from == nil, query.to == nil,
              let raw = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (query, nil)
        }
        let text = raw.lowercased()
        var resolved = query

        if text.contains("first thing") && (text.contains("screen") || text.contains("morning")) {
            let day = calendar.startOfDay(for: now)
            resolved.text = nil
            resolved.from = calendar.date(byAdding: .hour, value: 5, to: day)
            resolved.to = calendar.date(byAdding: .hour, value: 12, to: day)
            resolved.limit = 8
            resolved.sortOrder = .chronological
            resolved.anchorAfterWake = true
            resolved.meaningfulOnly = true
            return (resolved, .firstMorningActivity)
        }

        if text.contains("last night") {
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
            resolved.text = nil
            resolved.from = calendar.date(byAdding: .hour, value: 18, to: yesterday)
            resolved.to = calendar.date(byAdding: .hour, value: 5, to: today)
            resolved.limit = 20
            resolved.sortOrder = .chronological
            resolved.meaningfulOnly = true
            return (resolved, .lastNight)
        }

        if let day = parsedCalendarDay(in: text, now: now, calendar: calendar) {
            resolved.text = nil
            resolved.from = calendar.startOfDay(for: day)
            resolved.to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            resolved.limit = 50
            resolved.sortOrder = .chronological
            resolved.meaningfulOnly = true
            return (resolved, .calendarDay(day))
        }

        let latestPhrases = [
            "working on last", "work on last", "doing last", "did last", "most recently working",
        ]
        if latestPhrases.contains(where: text.contains) {
            resolved.text = nil
            resolved.limit = 1
            resolved.sortOrder = .recent
            resolved.meaningfulOnly = true
            return (resolved, .latest)
        }
        return (query, nil)
    }

    private static func parsedCalendarDay(in text: String, now: Date, calendar: Calendar) -> Date? {
        let months = "january|february|march|april|may|june|july|august|september|october|november|december"
        let patterns = [
            "\\b([0-3]?\\d)\\s+(\(months))(?:\\s+(\\d{4}))?\\b",
            "\\b(\(months))\\s+([0-3]?\\d)(?:,?\\s+(\\d{4}))?\\b",
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges == 4 else { continue }
            let dayIndex = index == 0 ? 1 : 2
            let monthIndex = index == 0 ? 2 : 1
            guard let dayRange = Range(match.range(at: dayIndex), in: text),
                  let monthRange = Range(match.range(at: monthIndex), in: text),
                  let day = Int(text[dayRange]) else { continue }
            let year: Int
            if let yearRange = Range(match.range(at: 3), in: text), let explicit = Int(text[yearRange]) {
                year = explicit
            } else {
                year = calendar.component(.year, from: now)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM"
            guard let monthDate = formatter.date(from: String(text[monthRange]).capitalized) else { continue }
            let month = calendar.component(.month, from: monthDate)
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) { return date }
        }
        return nil
    }
}

struct ContextStoreHealth: Equatable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        case indexing
        case unavailable
    }

    let state: State
    let observationCount: Int
    let sessionCount: Int
    let taskCount: Int
    let spanCount: Int
    let evidenceCount: Int
    let semanticVectorCount: Int
    let detail: String
}

struct ContextStorageUsage: Equatable, Codable, Sendable {
    let databaseBytes: Int64
    let rawRetentionDays: Int?
    let redactionPolicyVersion: Int
    let semanticSearchEnabled: Bool
}

enum MemoryCorrectionKind: String, Codable, Sendable {
    case rename
    case pin
    case assignWorkstream = "assign_workstream"
    case merge
    case split
    case moveSpan = "move_span"
    case delete
}
