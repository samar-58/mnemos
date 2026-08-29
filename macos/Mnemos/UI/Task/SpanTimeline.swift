import SwiftUI

/// One line of a task's activity.
///
/// Spans break on window title, document, and a one minute idle gap, so a
/// stretch of steady work in one file becomes several spans that all describe
/// themselves identically — "Worked in Ghostty on logistics-mobile-app-porter-v1",
/// three times in a row. Consecutive spans that read the same are shown as one
/// step covering the whole stretch, with the number of visits when it is more
/// than one.
struct ActivityStep: Identifiable, Equatable {
    /// The spans this step stands for, in the order the store returned them.
    let spans: [ActivitySpan]
    let text: String

    /// The first span's id, which is also the row's selection tag; the browser
    /// expands it back to every member before splitting or moving.
    var id: String { spans[0].id }

    var spanIDs: [String] { spans.map(\.id) }

    var visitCount: Int { spans.count }

    var startedAt: Date { spans.map(\.startedAt).min() ?? spans[0].startedAt }

    var endedAt: Date { spans.map(\.endedAt).max() ?? spans[0].endedAt }

    /// Time inside the step, summed rather than measured end to end, so a gap
    /// between two visits is not counted as work.
    var activeSeconds: TimeInterval {
        spans.reduce(0) { $0 + max(0, $1.endedAt.timeIntervalSince($1.startedAt)) }
    }

    var url: String? { spans.compactMap(\.url).first }

    var documentPath: String? { spans.compactMap(\.documentPath).first }

    var applicationName: String { spans[0].applicationName }

    var windowTitle: String? { spans.compactMap(\.windowTitle).first }

    /// Folds consecutive look-alike spans together.
    static func collapse(_ spans: [ActivitySpan]) -> [ActivityStep] {
        var steps: [ActivityStep] = []
        var run: [ActivitySpan] = []
        var runText: String?

        func flush() {
            guard let runText, !run.isEmpty else { return }
            steps.append(ActivityStep(spans: run, text: runText))
            run = []
        }

        for span in spans {
            let text = Narrative.step(for: span)
            if text != runText {
                flush()
                runText = text
            }
            run.append(span)
        }
        flush()
        return steps
    }
}

/// One step of the task, on a time rail: "1:02 — Worked in Xcode on AppModel.swift".
struct SpanRow: View {
    let step: ActivityStep

    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    private var artifact: String? {
        step.url ?? step.documentPath
    }

    private var glyph: String {
        if step.url != nil { return Glyph.browser }
        if step.documentPath != nil { return Glyph.document }
        return Glyph.application
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(step.startedAt, format: .dateTime.hour().minute())
                .font(TypeScale.numeric)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Image(systemName: glyph)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 16)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(step.text)
                        .font(TypeScale.rowBody)
                        .lineLimit(2)
                    if step.visitCount > 1 {
                        Chip(text: "×\(step.visitCount)")
                            .help("Returned to this \(step.visitCount) times")
                    }
                    Spacer(minLength: Spacing.s)
                    Text(Elapsed.label(seconds: step.activeSeconds))
                        .font(TypeScale.numeric)
                        .foregroundStyle(.tertiary)
                }

                if showsDeveloperDetails, let artifact {
                    CodeText(text: artifact, lineLimit: 1)
                }
            }
        }
        .padding(.vertical, Spacing.xs - 1)
        .help(artifact ?? step.windowTitle ?? step.applicationName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [step.startedAt.formatted(date: .omitted, time: .shortened), step.text]
        if step.visitCount > 1 { parts.append("\(step.visitCount) visits") }
        return parts.joined(separator: ", ")
    }
}
