import Foundation

/// Executes persisted jobs one at a time. Scheduling remains independent of
/// capture, and every operation can be retried after sleep, crash, or logout.
actor DerivationCoordinator {
    private let store: PersonalContextStore
    private let provider: CodexAppServerProvider
    private var isRunning = false

    init(store: PersonalContextStore, provider: CodexAppServerProvider) {
        self.store = store
        self.provider = provider
    }

    func runDueJobs(now: Date = .now) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try await store.enqueueDueJobs(now: now)
            for job in try await store.dueJobs(limit: 8, now: now) {
                if Task.isCancelled { return }
                await process(job)
            }
        } catch {
            // Durable jobs retain their state; the next scheduler pass retries.
        }
    }

    func runNow() async {
        await runDueJobs(now: .now)
    }

    private func process(_ job: DerivationJob) async {
        do {
            try await store.markJob(job.id, status: .running)
            switch job.kind {
            case .episodeExtraction:
                try await extract(job)
            case .dailyConsolidation:
                try await store.consolidateDay(from: job.windowStart, to: job.windowEnd)
                try await store.minePatterns()
            case .patternMining:
                try await store.minePatterns()
            case .skillExplanation:
                // Candidate generation is already evidence-backed. Model naming
                // is intentionally deferred until a candidate has enough support.
                try await store.minePatterns()
            }
            try await store.markJob(job.id, status: .completed)
        } catch {
            let delay = min(pow(2, Double(max(job.attempts, 0))) * 900, 21_600)
            let terminal = job.attempts >= 3
            try? await store.markJob(
                job.id, status: terminal ? .failed : .deferred,
                error: String(error.localizedDescription.prefix(500)),
                retryAt: terminal ? nil : Date.now.addingTimeInterval(delay)
            )
        }
    }

    private func extract(_ job: DerivationJob) async throws {
        let packet = try await store.evidencePacket(from: job.windowStart, to: job.windowEnd)
        guard !packet.tasks.isEmpty else { return }
        guard await store.cloudEnrichmentEnabled else { return }
        guard await provider.isAvailable() else { throw CodexProviderError.unavailable }
        if let limit = try await provider.rateLimitStatus(), limit.usedPercent >= 80 {
            try await store.markJob(
                job.id, status: .deferred, error: "Codex quota is above the 80% safety threshold.",
                retryAt: limit.resetsAt.map { max($0.addingTimeInterval(30), Date.now.addingTimeInterval(300)) }
                    ?? Date.now.addingTimeInterval(3_600)
            )
            return
        }
        let models = try await provider.availableModels()
        guard !models.isEmpty else { throw CodexProviderError.protocolFailure("No Codex models are available.") }
        let configured = UserDefaults.standard.string(forKey: PersonalContextStore.extractionModelDefaultsKey)
        let model = configured.flatMap { models.contains($0) ? $0 : nil }
            ?? (models.contains("gpt-5.6-luna") ? "gpt-5.6-luna" : models[0])
        let synthesis = try await provider.synthesize(packet: packet, model: model, effort: "low")
        try await store.applySynthesis(
            synthesis, packet: packet, provider: provider.providerID, model: model, effort: "low"
        )
    }
}
