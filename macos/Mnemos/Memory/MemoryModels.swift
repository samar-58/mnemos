import Foundation

struct MemoryEpisode: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let title: String
    let summary: String
    let projectKey: String?
    let applications: [String]
    let artifacts: [String]
    let lastState: String?
    let eventCount: Int
    let importance: Double
    let isOpen: Bool
}

struct MemorySearchResult: Identifiable, Equatable, Codable, Sendable {
    let episode: MemoryEpisode
    let score: Double
    let highlights: [String]

    var id: String { episode.id }
}

struct EpisodeEvidence: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let timestamp: Date
    let kind: String
    let applicationName: String
    let windowTitle: String?
    let url: String?
    let documentPath: String?
    let target: String?
    let detail: String?
}

struct MemoryStoreHealth: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case unavailable(String)
    }

    let state: State
    let observationCount: Int
    let episodeCount: Int

    var label: String {
        switch state {
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

    var detail: String {
        switch state {
        case .ready:
            "\(episodeCount) episodes · \(observationCount) observations"
        case let .unavailable(message):
            message
        }
    }
}
