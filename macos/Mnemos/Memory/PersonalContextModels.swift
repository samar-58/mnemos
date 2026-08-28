import Foundation

enum ResumeStateKind: String, Codable, CaseIterable, Sendable {
    case document
    case webpage
    case terminal
    case selection
    case text
    case window
}

struct ResumeState: Equatable, Codable, Sendable {
    let kind: ResumeStateKind
    let value: String
    let application: String
    let timestamp: Date
    let supportingEvidenceID: String?
}

enum MemoryScope: String, Codable, CaseIterable, Sendable {
    case episode
    case dailyWorkstream = "daily_workstream"
    case dailyRecap = "daily_recap"
}

enum MemoryLifeCycle: String, Codable, CaseIterable, Sendable {
    case pendingEnrichment = "pending_enrichment"
    case current
    case localOnly = "local_only"
    case failed
    case superseded
}

enum MemoryAuthorship: String, Codable, CaseIterable, Sendable {
    case deterministic
    case modelDerived = "model_derived"
    case userAuthored = "user_authored"
}

enum TaskProgressState: String, Codable, CaseIterable, Sendable {
    case inProgress = "in_progress"
    case completed
    case blocked
    case unknown
}

struct DerivedMemory: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let versionID: String
    let version: Int
    let scope: MemoryScope
    let scopeID: String
    let workstream: Workstream?
    let startedAt: Date
    let endedAt: Date
    let title: String
    let summary: String
    let progress: TaskProgressState
    let accomplishments: [String]
    let blockers: [String]
    let openLoops: [String]
    let artifacts: [String]
    let applications: [String]
    let resumeState: ResumeState?
    let status: MemoryLifeCycle
    let authorship: MemoryAuthorship
    let sourceCoverage: Double
    let omittedSourceCount: Int
    let provider: String?
    let model: String?
    let createdAt: Date
    let isUserLocked: Bool
}

struct MemoryClaim: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let memoryVersionID: String
    let kind: String
    let text: String
    let confidence: Double
    let evidenceIDs: [String]
}

struct WorkstreamState: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let workstream: Workstream
    let summary: String
    let decisions: [String]
    let blockers: [String]
    let openLoops: [String]
    let artifacts: [String]
    let lastMemoryID: String?
    let updatedAt: Date
}

struct WorkflowTrace: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let taskID: String
    let workstreamID: String?
    let actions: [String]
    let applications: [String]
    let fingerprint: String
    let startedAt: Date
    let endedAt: Date
}

enum PatternStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case approved
    case rejected
    case superseded
}

struct WorkflowPattern: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let summary: String
    let scopeWorkstreamID: String?
    let trigger: String
    let workflow: [String]
    let confidence: Double
    let occurrenceCount: Int
    let firstSeenAt: Date
    let lastSeenAt: Date
    let status: PatternStatus
    let evidenceTaskIDs: [String]
}

enum PersonalSkillStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case approved
    case rejected
    case retired
}

struct PersonalSkill: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let currentVersionID: String?
    let title: String
    let description: String
    let scopeWorkstreamID: String?
    let status: PersonalSkillStatus
    let confidence: Double
    let occurrenceCount: Int
    let updatedAt: Date
}

struct SkillVersion: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let skillID: String
    let version: Int
    let trigger: String
    let workflow: [String]
    let preferences: [String]
    let constraints: [String]
    let verification: [String]
    let evidenceMemoryIDs: [String]
    let approvedAt: Date?
    let createdAt: Date
}

/// Local, content-free records of how an approved skill has actually been used.
/// Only the skill identity, surface, and time are stored: never the agent's
/// prompt, the query text, or anything the agent returned.
enum SkillEventKind: String, Codable, CaseIterable, Sendable {
    case retrieved
    case exported
    case exportRemoved = "export_removed"
}

enum SkillEventSurface: String, Codable, CaseIterable, Sendable {
    case agentAPI = "agent_api"
    case app
}

struct SkillActivity: Equatable, Codable, Sendable {
    let skillID: String
    let retrievalCount: Int
    let lastRetrievedAt: Date?
    let exportedVersion: Int?
    let lastExportedAt: Date?

    static func empty(skillID: String) -> SkillActivity {
        SkillActivity(
            skillID: skillID, retrievalCount: 0, lastRetrievedAt: nil,
            exportedVersion: nil, lastExportedAt: nil
        )
    }

    var isExported: Bool { exportedVersion != nil }
}

struct RelevantSkill: Identifiable, Equatable, Codable, Sendable {
    let skill: PersonalSkill
    let version: SkillVersion
    let score: Double
    let matchReasons: [String]

    var id: String { skill.id }
}

struct MemorySearchV3Result: Identifiable, Equatable, Codable, Sendable {
    let memory: DerivedMemory
    let score: Double
    let highlights: [String]
    let matchReasons: [String]
    let evidencePreviews: [EvidenceItem]

    var id: String { memory.id }
}

struct PersonalContextPack: Equatable, Codable, Sendable {
    let query: String?
    let currentState: [WorkstreamState]
    let memories: [MemorySearchV3Result]
    let approvedSkills: [RelevantSkill]
    let evidence: [EvidenceItem]
    let trustBoundary: String
    let generatedAt: Date
}

enum DerivationJobKind: String, Codable, CaseIterable, Sendable {
    case episodeExtraction = "episode_extraction"
    case dailyConsolidation = "daily_consolidation"
    case patternMining = "pattern_mining"
    case skillExplanation = "skill_explanation"
}

enum DerivationJobStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case deferred
    case completed
    case failed
}

struct DerivationJob: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: DerivationJobKind
    let windowStart: Date
    let windowEnd: Date
    let status: DerivationJobStatus
    let attempts: Int
    let nextRunAt: Date?
    let error: String?
    let createdAt: Date
    let updatedAt: Date
}

struct DerivationStatus: Equatable, Codable, Sendable {
    let cloudEnrichmentEnabled: Bool
    let provider: String
    let providerAvailable: Bool
    let pendingJobs: Int
    let failedJobs: Int
    let lastSuccessfulRunAt: Date?
    let nextExtractionAt: Date
    let nextConsolidationAt: Date
}

struct EvidencePacket: Equatable, Codable, Sendable {
    let schemaVersion: Int
    let windowStart: Date
    let windowEnd: Date
    let tasks: [EvidencePacketTask]
}

struct EvidencePacketTask: Equatable, Codable, Sendable {
    let taskID: String
    let workstreamID: String?
    let workstreamName: String?
    let startedAt: Date
    let endedAt: Date
    let applications: [String]
    let artifacts: [String]
    let deterministicTitle: String
    let deterministicSummary: String
    let resumeState: ResumeState?
    let evidence: [EvidencePacketItem]
    let sourceCoverage: Double
    let omittedSourceCount: Int
}

struct EvidencePacketItem: Equatable, Codable, Sendable {
    let evidenceID: String
    let timestamp: Date
    let kind: String
    let application: String
    let text: String?
    let artifact: String?
}

struct MemorySynthesisBatch: Equatable, Codable, Sendable {
    let memories: [MemorySynthesis]
}

struct MemorySynthesis: Equatable, Codable, Sendable {
    let taskID: String
    let title: String
    let summary: String
    let progress: TaskProgressState
    let accomplishments: [String]
    let blockers: [String]
    let openLoops: [String]
    let likelyNextStep: String?
    let workflow: [String]
    let claims: [MemorySynthesisClaim]
}

struct MemorySynthesisClaim: Equatable, Codable, Sendable {
    let kind: String
    let text: String
    let confidence: Double
    let evidenceIDs: [String]
}
