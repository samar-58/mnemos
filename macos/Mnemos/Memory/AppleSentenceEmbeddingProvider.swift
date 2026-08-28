import Accelerate
import CryptoKit
import Foundation
import NaturalLanguage

struct SemanticVector: Sendable {
    let provider: String
    let language: String
    let revision: Int
    let dimension: Int
    let contentHash: String
    let values: [Float]

    var data: Data {
        values.withUnsafeBytes { Data($0) }
    }
}

actor AppleSentenceEmbeddingProvider {
    static let providerID = "apple.nl-sentence"

    func embed(_ value: String) -> SemanticVector? {
        Self.makeEmbedding(value)
    }

    nonisolated static func makeEmbedding(_ value: String) -> SemanticVector? {
        let text = String(value.prefix(8_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let detected = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        let language = NLEmbedding.sentenceEmbedding(for: detected) == nil ? NLLanguage.english : detected
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: language)
        guard revision > 0,
              let embedding = NLEmbedding.sentenceEmbedding(for: language, revision: revision),
              let doubles = embedding.vector(for: text),
              doubles.count == embedding.dimension else {
            return nil
        }

        var values = doubles.map(Float.init)
        var sumSquares: Float = 0
        vDSP_svesq(values, 1, &sumSquares, vDSP_Length(values.count))
        let magnitude = sqrt(sumSquares)
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        var divisor = magnitude
        vDSP_vsdiv(values, 1, &divisor, &values, 1, vDSP_Length(values.count))

        return SemanticVector(
            provider: providerID,
            language: language.rawValue,
            revision: revision,
            dimension: embedding.dimension,
            contentHash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            values: values
        )
    }

    nonisolated static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0, data.count == dimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return nil }
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float.self),
                count: dimension
            ))
        }
    }

    nonisolated static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result.isFinite ? result : nil
    }
}
