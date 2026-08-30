import Foundation

/// Executes persisted jobs one at a time. Scheduling remains independent of
/// capture, and every operation can be retried after sleep, crash, or logout.
actor DerivationCoordinator {
    private enum ExecutionResult {
        case completed(inputCount: Int, outputCount: Int)
        case skipped(String)
        case deferred(String, retryAt: Date)
    }

    private let store: PersonalContextStore
    private let provider: CodexAppServerProvider
    private var isRunning = false

    init(store: PersonalContextStore, provider: CodexAppServerProvider) {
        self.store = store
        self.provider = provider
    }

    func runDueJobs(now: Date = .now) async -> DerivationRunOutcome {
        guard !isRunning else {
            var outcome = DerivationRunOutcome.noWork
            outcome.messages = ["Memory processing is already running."]
            return outcome
        }
        isRunning = true
        defer { isRunning = false }
        var outcome = DerivationRunOutcome.noWork
        do {
            try await store.enqueueDueJobs(now: now)
            for job in try await store.dueJobs(limit: 8, now: now) {
                if Task.isCancelled { break }
                let result = await process(job)
                outcome.processed += 1
                outcome.succeeded += result.succeeded
                outcome.skipped += result.skipped
                outcome.failed += result.failed
                outcome.deferred += result.deferred
                outcome.messages.append(contentsOf: result.messages)
            }
        } catch {
            outcome.failed += 1
            outcome.messages.append(String(error.localizedDescription.prefix(500)))
        }
        return outcome
    }

    func runNow() async -> DerivationRunOutcome {
        await runDueJobs(now: .now)
    }

    private func process(_ job: DerivationJob) async -> DerivationRunOutcome {
        let startedAt = Date.now
        var outcome = DerivationRunOutcome.noWork
        do {
            try await store.markJob(job.id, status: .running)
            let execution: ExecutionResult
            switch job.kind {
            case .episodeExtraction:
                execution = try await extract(job)
            case .dailyConsolidation:
                try await store.consolidateDay(from: job.windowStart, to: job.windowEnd)
                try await store.minePatterns()
                execution = .completed(inputCount: 1, outputCount: 1)
            case .patternMining:
                try await store.minePatterns()
                execution = .completed(inputCount: 1, outputCount: 1)
            case .skillExplanation:
                // Candidate generation is already evidence-backed. Model naming
                // is intentionally deferred until a candidate has enough support.
                try await store.minePatterns()
                execution = .completed(inputCount: 1, outputCount: 1)
            }
            switch execution {
            case let .completed(inputCount, outputCount):
                try await store.markJob(job.id, status: .completed)
                try await store.recordDerivationRun(
                    job: job, status: .completed, inputCount: inputCount,
                    outputCount: outputCount, startedAt: startedAt
                )
                outcome.succeeded = 1
            case let .skipped(message):
                try await store.markJob(job.id, status: .completed)
                try await store.recordDerivationRun(
                    job: job, status: .completed, error: message, startedAt: startedAt
                )
                outcome.skipped = 1
                outcome.messages = [message]
            case let .deferred(message, retryAt):
                try await store.markJob(job.id, status: .deferred, error: message, retryAt: retryAt)
                try await store.recordDerivationRun(
                    job: job, status: .deferred, error: message, startedAt: startedAt
                )
                outcome.deferred = 1
                outcome.messages = [message]
            }
        } catch {
            let delay = min(pow(2, Double(max(job.attempts, 0))) * 900, 21_600)
            let terminal = job.attempts >= 3
            let message = String(error.localizedDescription.prefix(500))
            let status: DerivationJobStatus = terminal ? .failed : .deferred
            try? await store.markJob(
                job.id, status: status, error: message,
                retryAt: terminal ? nil : Date.now.addingTimeInterval(delay)
            )
            try? await store.recordDerivationRun(
                job: job, status: status, error: message, startedAt: startedAt
            )
            if terminal { outcome.failed = 1 } else { outcome.deferred = 1 }
            outcome.messages = [message]
        }
        return outcome
    }

    private func extract(_ job: DerivationJob) async throws -> ExecutionResult {
        let packet = try await store.evidencePacket(from: job.windowStart, to: job.windowEnd)
        guard !packet.tasks.isEmpty else {
            return .skipped("No eligible, consented tasks were present in this extraction window.")
        }
        guard await store.cloudEnrichmentEnabled else {
            return .skipped("Cloud enrichment is off; deterministic local memories remain available.")
        }
        guard await provider.isAvailable() else { throw CodexProviderError.unavailable }
        if let limit = try await provider.rateLimitStatus(), limit.usedPercent >= 80 {
            return .deferred(
                "Codex quota is above the 80% safety threshold.",
                retryAt: limit.resetsAt.map { max($0.addingTimeInterval(30), Date.now.addingTimeInterval(300)) }
                    ?? Date.now.addingTimeInterval(3_600)
            )
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
        return .completed(inputCount: packet.tasks.count, outputCount: synthesis.memories.count)
    }
}
