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
