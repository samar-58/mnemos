import SwiftUI

/// One step of the task, on a time rail: "1:02 — Worked in Xcode on AppModel.swift".
struct SpanRow: View {
    let span: ActivitySpan

    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    private var artifact: String? {
        span.url ?? span.documentPath
    }

    private var glyph: String {
        if span.url != nil { return Glyph.browser }
        if span.documentPath != nil { return Glyph.document }
        return Glyph.application
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(span.startedAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Capsule()
                .fill(.tint.opacity(0.35))
                .frame(width: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs - 1) {
                HStack(spacing: Spacing.s - 2) {
                    Image(systemName: glyph)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Narrative.step(for: span))
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: Spacing.s)
                    Text(Elapsed.label(from: span.startedAt, to: span.endedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if showsDeveloperDetails, let artifact {
                    CodeText(text: artifact, lineLimit: 1)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .help(artifact ?? span.windowTitle ?? span.applicationName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(span.startedAt.formatted(date: .omitted, time: .shortened)), \(Narrative.step(for: span))"
        )
    }
}
